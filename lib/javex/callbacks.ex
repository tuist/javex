defmodule Javex.Callbacks do
  @moduledoc false

  alias Javex.Native

  def new(limits), do: %{limits: limits, calls: 0}

  def native(runtime, mod, input, limits, control, owner) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(owner)

    try do
      :ok =
        Native.run_start(
          runtime,
          mod.bytes,
          input,
          Javex.Options.native(limits, mod.mode),
          control
        )

      await_native(new(limits), control, monitor)
    after
      Native.cancel(control)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_native(state, control, monitor) do
    receive do
      {:native_result, result} ->
        result

      {:native_callback, reply, request} ->
        {response, state} = handle(request, state, monitor)
        Native.callback_reply(reply, response)
        await_native(state, control, monitor)

      :cancel ->
        Native.cancel(control)
        await_native(state, control, monitor)

      {:DOWN, ^monitor, :process, _, _} ->
        Native.cancel(control)
        await_native(state, control, monitor)
    end
  end

  # Independently enforce authorization and budgets in BEAM, even if an isolated
  # child forges requests after a native-code escape.
  def handle(request, %{limits: limits, calls: calls} = state, monitor) do
    response =
      cond do
        calls >= limits.max_callback_calls ->
          abort("callback_limit", "Callback call limit exceeded")

        byte_size(request) > limits.max_callback_input ->
          abort("callback_limit", "Callback input limit exceeded")

        true ->
          dispatch(request, limits, monitor)
      end

    {response, %{state | calls: calls + 1}}
  end

  defp dispatch(request, limits, monitor) do
    with {:ok, %{"name" => name, "argument" => argument}} <- Jason.decode(request),
         true <- is_binary(name) and byte_size(name) in 1..128,
         {:ok, callback} <- Map.fetch(limits.callbacks, name) do
      deadline = min(limits.deadline, now() + limits.callback_timeout)

      if now() < deadline do
        invoke(callback, argument, deadline, limits.max_callback_output, monitor)
      else
        abort("callback_timeout", "Callback deadline elapsed")
      end
    else
      _ -> failure("callback_denied", "Callback not granted")
    end
  end

  defp invoke(callback, argument, deadline, maximum, owner_monitor) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          response =
            try do
              callback.(argument, %{deadline: deadline}) |> encode_result(maximum)
            catch
              _, _ -> failure("callback_failed", "Callback failed")
            end

          send(parent, {ref, response})
        end,
        [:link, :monitor]
      )

    try do
      receive do
        {^ref, response} ->
          if now() < deadline, do: response, else: abort("callback_timeout", "Callback timed out")

        {:DOWN, ^monitor, :process, ^pid, _} ->
          failure("callback_failed", "Callback failed")

        {:DOWN, ^owner_monitor, :process, _, _} ->
          abort("cancelled", "Execution cancelled")

        :cancel ->
          abort("cancelled", "Execution cancelled")
      after
        max(deadline - now(), 0) -> abort("callback_timeout", "Callback timed out")
      end
    after
      Process.unlink(pid)
      stopped = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^stopped, :process, ^pid, _} -> :ok
      end

      Process.demonitor(monitor, [:flush])
    end
  end

  defp encode_result({:ok, value}, maximum), do: encode("ok", value, maximum)

  defp encode_result({:error, %{"code" => code, "message" => message} = error}, maximum)
       when is_binary(code) and is_binary(message) do
    encode("error", Map.take(error, ["code", "message"]), maximum)
  end

  defp encode_result(_, _), do: failure("callback_failed", "Invalid callback result")

  defp encode(kind, value, maximum) do
    if json?(value) do
      iodata = Jason.encode_to_iodata!(value)

      if IO.iodata_length(iodata) <= maximum do
        IO.iodata_to_binary(["[", Jason.encode!(kind), ",", iodata, "]"])
      else
        abort("callback_limit", "Callback output limit exceeded")
      end
    else
      failure("callback_failed", "Callback result must be JSON-compatible")
    end
  end

  defp json?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json?(item) end)

  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  defp json?(value), do: is_binary(value) or is_number(value) or value in [true, false, nil]

  defp failure(code, message),
    do: Jason.encode!(["error", %{"code" => code, "message" => message}])

  defp abort(code, message), do: Jason.encode!(["abort", %{"code" => code, "message" => message}])
  defp now, do: System.monotonic_time(:millisecond)
end
