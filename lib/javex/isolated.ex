defmodule Javex.Isolated do
  @moduledoc false

  alias Javex.{Callbacks, Options}

  @max_transport 64 * 1024 * 1024
  @kinds Map.new(
           ~w(timeout cancelled fuel_exhausted oom js_error trap output_limit diagnostic_limit input_limit module_limit compile_error worker_error callback_limit callback_timeout),
           &{&1, String.to_atom(&1)}
         )

  def available do
    with {:unix, :linux} <- :os.type(),
         {:ok, %{type: :regular, mode: mode}} <- File.stat(executable()),
         true <- Bitwise.band(mode, 0o111) != 0 do
      {:ok, nil}
    else
      _ -> {:error, "isolated backend requires Linux and an executable javex_worker"}
    end
  end

  def run(plugin, mod, input, limits, memory, owner) do
    call("run", plugin, mod.bytes, input, mod.mode, limits, memory, owner)
  end

  def compile(plugin, source, mode, limits, memory, owner) do
    with {:ok, bytes} <- call("compile", plugin, source, <<>>, mode, limits, memory, owner) do
      {:ok, {bytes, if(mode == :dynamic, do: :crypto.hash(:sha256, plugin), else: <<>>)}}
    end
  end

  defp call(operation, plugin, module, input, mode, limits, memory, owner) do
    Process.flag(:trap_exit, true)
    limits = Map.put_new(limits, :deadline, System.monotonic_time(:millisecond) + limits.timeout)

    budgets =
      limits
      |> Options.native(mode)
      |> Map.update!(:env, &Enum.map(&1, fn {key, value} -> [key, value] end))

    header = Jason.encode!(%{operation: operation, limits: budgets})
    frames = [header, plugin, module, input]

    maximum =
      min(max(limits.max_module, max(limits.max_output, limits.max_stderr)), @max_transport)

    if Enum.sum(Enum.map(frames, &byte_size/1)) > @max_transport do
      {:error, {:input_limit, "isolated IPC request exceeds 64 MiB"}}
    else
      port =
        Port.open({:spawn_executable, executable()}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          args: ["--supervise", to_string(memory), to_string(limits.timeout), to_string(maximum)],
          env: Enum.map(System.get_env(), fn {key, _value} -> {to_charlist(key), false} end)
        ])

      monitor = Process.monitor(owner)

      try do
        Port.command(port, Enum.map(frames, &[<<byte_size(&1)::32>>, &1]))

        receive_result(port, monitor, %{
          buffer: <<>>,
          result: nil,
          failure: nil,
          maximum: maximum,
          callbacks: Callbacks.new(limits),
          cancelled: false
        })
      after
        Process.demonitor(monitor, [:flush])
        if Port.info(port), do: Port.close(port)
      end
    end
  rescue
    error -> {:error, {:worker_error, "isolated worker unavailable: #{Exception.message(error)}"}}
  end

  defp receive_result(port, monitor, state) do
    receive do
      {^port, {:data, bytes}} ->
        maximum = max(state.maximum, state.callbacks.limits.max_callback_input) + 4096

        if byte_size(state.buffer) + byte_size(bytes) <= maximum do
          case consume(port, monitor, %{state | buffer: state.buffer <> bytes}) do
            {:ok, state} -> receive_result(port, monitor, state)
            error -> error
          end
        else
          {:error, {:worker_error, "isolated worker exceeded IPC response limit"}}
        end

      {^port, {:exit_status, _}} when not is_nil(state.failure) ->
        state.failure

      {^port, {:exit_status, 0}} ->
        if state.buffer == <<>> and state.result, do: state.result, else: invalid_response()

      {^port, {:exit_status, 124}} ->
        {:error, {:timeout, "isolated worker timed out"}}

      {^port, {:exit_status, 125}} ->
        {:error, {:cancelled, "isolated worker cancelled"}}

      {^port, {:exit_status, status}} ->
        {:error, {:worker_error, "isolated worker exited (status #{status})"}}

      :cancel ->
        receive_result(port, monitor, cancel(port, state))

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        receive_result(port, monitor, cancel(port, state))
    end
  end

  defp cancel(port, state) do
    if !state.cancelled, do: Port.command(port, <<1>>)
    %{state | cancelled: true}
  end

  defp consume(port, monitor, state) do
    case message(state.buffer, state.maximum, state.callbacks.limits.max_callback_input) do
      :more ->
        {:ok, state}

      {:ok, "callback", request, rest} when not state.cancelled and is_nil(state.result) ->
        state = callback_reply(port, monitor, request, %{state | buffer: rest})
        consume(port, monitor, state)

      {:ok, "callback", _, rest} when state.cancelled ->
        consume(port, monitor, %{state | buffer: rest})

      {:ok, kind, bytes, rest} when is_nil(state.result) and kind != "callback" ->
        consume(port, monitor, %{state | buffer: rest, result: decode_result(kind, bytes)})

      _ ->
        invalid_response()
    end
  end

  defp decode_result("ok", bytes), do: {:ok, bytes}

  defp decode_result(kind, bytes) when is_map_key(@kinds, kind),
    do: {:error, {Map.fetch!(@kinds, kind), bytes}}

  defp decode_result(_, _), do: invalid_response()

  defp callback_reply(port, monitor, request, state) do
    {response, callbacks} = Callbacks.handle(request, state.callbacks, monitor)
    state = %{state | callbacks: callbacks}

    case Jason.decode!(response) do
      ["abort", %{"code" => code, "message" => message}] ->
        cancel(port, %{state | failure: {:error, {Map.fetch!(@kinds, code), message}}})

      _ ->
        Port.command(port, [<<2, byte_size(response)::32>>, response])
        state
    end
  end

  defp message(<<length::32, _::binary>>, _, _) when length > 4096, do: :error

  defp message(
         <<length::32, header::binary-size(length), size::32, rest::binary>>,
         maximum,
         callback_max
       ) do
    with {:ok, kind} when is_binary(kind) <- Jason.decode(header),
         true <- size <= if(kind == "callback", do: callback_max, else: maximum) do
      case rest do
        <<bytes::binary-size(size), tail::binary>> -> {:ok, kind, bytes, tail}
        _ -> :more
      end
    else
      _ -> :error
    end
  end

  defp message(_, _, _), do: :more
  defp invalid_response, do: {:error, {:worker_error, "invalid isolated worker response"}}
  defp executable, do: Application.app_dir(:javex, "priv/native/javex_worker")
end
