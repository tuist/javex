defmodule Javex.Isolated do
  @moduledoc false

  alias Javex.Options

  @max_transport 64 * 1024 * 1024
  @kinds Map.new(
           ~w(timeout cancelled fuel_exhausted oom js_error trap output_limit diagnostic_limit input_limit module_limit compile_error worker_error),
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
        receive_result(port, monitor, [], 0, maximum + 4096, false)
      after
        Process.demonitor(monitor, [:flush])
        if Port.info(port), do: Port.close(port)
      end
    end
  rescue
    error -> {:error, {:worker_error, "isolated worker unavailable: #{Exception.message(error)}"}}
  end

  defp receive_result(port, monitor, chunks, size, maximum, cancelled) do
    receive do
      {^port, {:data, bytes}} when size + byte_size(bytes) <= maximum ->
        receive_result(
          port,
          monitor,
          [bytes | chunks],
          size + byte_size(bytes),
          maximum,
          cancelled
        )

      {^port, {:data, _bytes}} ->
        {:error, {:worker_error, "isolated worker exceeded IPC response limit"}}

      {^port, {:exit_status, 0}} ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary() |> decode_response()

      {^port, {:exit_status, 124}} ->
        {:error, {:timeout, "isolated worker timed out"}}

      {^port, {:exit_status, 125}} ->
        {:error, {:cancelled, "isolated worker cancelled"}}

      {^port, {:exit_status, status}} ->
        {:error, {:worker_error, "isolated worker exited (status #{status})"}}

      :cancel ->
        cancel(port, monitor, chunks, size, maximum, cancelled)

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        cancel(port, monitor, chunks, size, maximum, cancelled)
    end
  end

  defp cancel(port, monitor, chunks, size, maximum, cancelled) do
    if !cancelled, do: Port.command(port, <<1>>)
    receive_result(port, monitor, chunks, size, maximum, true)
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
