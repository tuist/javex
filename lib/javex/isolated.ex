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

  def run(plugin, mod, input, limits, memory, owner, broker) do
    call("run", [plugin, mod.bytes, input], mod.mode, limits, memory, owner, broker)
  end

  def compile(plugin, source, mode, limits, memory, owner) do
    with {:ok, bytes} <- call("compile", [plugin, source, <<>>], mode, limits, memory, owner, nil) do
      {:ok, {bytes, if(mode == :dynamic, do: :crypto.hash(:sha256, plugin), else: <<>>)}}
    end
  end

  defp call(operation, payloads, mode, limits, memory, owner, broker) do
    budgets =
      limits
      |> Options.native(mode)
      |> Map.update!(:env, &Enum.map(&1, fn {key, value} -> [key, value] end))

    header = Jason.encode!(%{operation: operation, limits: budgets})
    frames = [header | payloads]

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

        max_frame =
          min(
            @max_transport,
            max(
              maximum,
              limits.max_callback_concurrency * (6 * limits.max_callback_input + 2048) + 4096
            )
          )

        receive_result(port, monitor, %{
          buffer: <<>>,
          size: 0,
          maximum: max_frame,
          output_limit: if(operation == "run", do: limits.max_output, else: limits.max_module),
          error_limit: max(4096, limits.max_stderr),
          broker: broker,
          broker_monitor: if(broker, do: elem(broker, 1)),
          token: if(broker, do: elem(broker, 2)),
          result: nil,
          failure: nil,
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
    token = state.token
    broker_monitor = state.broker_monitor

    receive do
      {^port, {:data, bytes}} when state.size + byte_size(bytes) <= @max_transport ->
        state = %{state | buffer: state.buffer <> bytes, size: state.size + byte_size(bytes)}

        case decode_events(state) do
          {:ok, state} -> receive_result(port, monitor, state)
          {:error, _} = error -> cancel(port, monitor, %{state | failure: error, buffer: <<>>})
        end

      {^port, {:data, _bytes}} ->
        cancel(port, monitor, %{
          state
          | failure: {:error, {:worker_error, "isolated worker exceeded IPC response limit"}},
            buffer: <<>>
        })

      {^port, {:exit_status, status}} ->
        state.failure || worker_result(state, status)

      :cancel ->
        cancel(port, monitor, state)

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        cancel(port, monitor, state)

      {:DOWN, ^broker_monitor, :process, _pid, _reason} when not is_nil(broker_monitor) ->
        cancel(port, monitor, %{
          state
          | failure: state.failure || {:error, {:trap, "callback broker stopped"}}
        })

      {:callback_reply, ^token, completion} when not is_nil(token) ->
        if !state.cancelled, do: Port.command(port, [<<byte_size(completion)::32>>, completion])
        receive_result(port, monitor, state)

      {:callback_error, ^token, kind, message} when not is_nil(token) ->
        cancel(port, monitor, %{state | failure: {:error, {kind, message}}})
    end
  end

  defp worker_result(state, 0),
    do: if(state.buffer == <<>> && state.result, do: state.result, else: invalid_response())

  defp worker_result(_state, 124), do: {:error, {:timeout, "isolated worker timed out"}}
  defp worker_result(_state, 125), do: {:error, {:cancelled, "isolated worker cancelled"}}

  defp worker_result(_state, status),
    do: {:error, {:worker_error, "isolated worker exited (status #{status})"}}

  defp cancel(port, monitor, state) do
    if !state.cancelled, do: Port.command(port, <<0::32>>)
    receive_result(port, monitor, %{state | cancelled: true})
  end

  defp decode_events(%{buffer: <<length::32, _::binary>>}) when length > 4096,
    do: invalid_response()

  defp decode_events(%{buffer: <<length::32, rest::binary>>} = state)
       when byte_size(rest) >= length + 4 do
    <<header::binary-size(length), size::32, payload::binary>> = rest

    cond do
      size > state.maximum ->
        invalid_response()

      byte_size(payload) < size ->
        {:ok, state}

      state.result ->
        invalid_response()

      true ->
        <<bytes::binary-size(size), tail::binary>> = payload
        handle_event(state, header, bytes, tail)
    end
  end

  defp decode_events(state), do: {:ok, state}

  defp handle_event(state, header, bytes, tail) do
    case Jason.decode(header) do
      {:ok, "callbacks"} when not is_nil(state.broker) ->
        if !state.cancelled, do: Callbacks.dispatch(state.broker, bytes)
        decode_events(%{state | buffer: tail})

      {:ok, "ok"} when byte_size(bytes) > state.output_limit ->
        invalid_response()

      {:ok, kind} when kind != "ok" and byte_size(bytes) > state.error_limit ->
        invalid_response()

      {:ok, _} ->
        result =
          decode_response(
            <<byte_size(header)::32, header::binary, byte_size(bytes)::32, bytes::binary>>
          )

        decode_events(%{state | buffer: tail, result: result})

      _ ->
        invalid_response()
    end
  end

  defp decode_response(<<length::32, rest::binary>>) when length <= 4096 do
    with <<header::binary-size(length), size::32, bytes::binary-size(size)>> <- rest,
         {:ok, kind} <- Jason.decode(header) do
      case kind do
        "ok" -> {:ok, bytes}
        kind when is_map_key(@kinds, kind) -> {:error, {Map.fetch!(@kinds, kind), bytes}}
        _ -> invalid_response()
      end
    else
      _ -> invalid_response()
    end
  end

  defp decode_response(_bytes), do: invalid_response()
  defp invalid_response, do: {:error, {:worker_error, "invalid isolated worker response"}}
  defp executable, do: Application.app_dir(:javex, "priv/native/javex_worker")
end
