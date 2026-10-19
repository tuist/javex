defmodule Javex.Callbacks do
  @moduledoc false

  # A per-execution broker. No callback runs on the runtime GenServer or a NIF
  # scheduler. Linked, monitored children cannot outlive a stopped broker.
  def start(limits) do
    parent = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        parent_monitor = Process.monitor(parent)

        loop(%{
          parent: parent,
          parent_monitor: parent_monitor,
          token: token,
          limits: limits,
          seen: MapSet.new(),
          jobs: %{}
        })
      end)

    {pid, monitor, token}
  end

  def dispatch({pid, _monitor, token}, bytes), do: send(pid, {:dispatch, token, bytes})

  def stop({pid, monitor, token}) do
    Process.demonitor(monitor, [:flush])
    monitor = Process.monitor(pid)
    send(pid, {:stop, token})

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    end
  end

  defp loop(state) do
    token = state.token
    parent_monitor = state.parent_monitor

    receive do
      {:dispatch, ^token, bytes} ->
        case dispatch_requests(state, bytes) do
          {:ok, state} -> loop(state)
          {:error, kind, message, state} -> fail(state, kind, message)
        end

      {:result, ^token, pid, result} when is_map_key(state.jobs, pid) ->
        loop(put_in(state.jobs[pid].result, result))

      {:DOWN, ^parent_monitor, :process, _, _} ->
        cleanup(state)

      {:DOWN, _ref, :process, pid, _reason} when is_map_key(state.jobs, pid) ->
        {job, jobs} = Map.pop(state.jobs, pid)
        Process.cancel_timer(job.timer)

        case job.result do
          {:fatal, message} ->
            fail(%{state | jobs: jobs}, :callback_limit, message)

          result ->
            result =
              result ||
                encode_error(
                  job.id,
                  "callback_failed",
                  "Host callback failed",
                  state.limits.max_callback_output
                )

            case result do
              {:fatal, message} ->
                fail(%{state | jobs: jobs}, :callback_limit, message)

              result ->
                send(state.parent, {:callback_reply, token, Jason.encode!([result])})
                loop(%{state | jobs: jobs})
            end
        end

      {:callback_timeout, pid} when is_map_key(state.jobs, pid) ->
        fail(state, :callback_timeout, "host callback timed out")

      {:stop, ^token} ->
        cleanup(state)

      _ ->
        loop(state)
    end
  end

  defp dispatch_requests(state, bytes) do
    max_frame =
      min(
        64 * 1024 * 1024,
        state.limits.max_callback_concurrency * (6 * state.limits.max_callback_input + 2048) +
          4096
      )

    with true <- byte_size(bytes) <= max_frame,
         {:ok, %{"requests" => requests}} when is_list(requests) <- Jason.decode(bytes),
         true <- length(requests) <= state.limits.max_callback_concurrency do
      dispatch_batch(state, requests)
    else
      _ -> {:error, :callback_limit, "invalid or oversized callback request frame", state}
    end
  end

  defp dispatch_batch(state, requests) do
    Enum.reduce_while(requests, {:ok, state}, fn request, {:ok, state} ->
      case dispatch_request(state, request) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, kind, message} -> {:halt, {:error, kind, message, state}}
      end
    end)
  end

  defp dispatch_request(state, %{"id" => id, "name" => name, "argument" => argument})
       when is_integer(id) and id > 0 and is_binary(name) and is_binary(argument) do
    with true <- admitted?(state, id),
         true <- valid_payload?(state, name, argument),
         {:ok, argument} <- Jason.decode(argument) do
      state = %{state | seen: MapSet.put(state.seen, id)}
      dispatch_granted(state, id, name, argument)
    else
      _ -> {:error, :callback_limit, "invalid callback request or callback budget exceeded"}
    end
  end

  defp dispatch_request(_state, _request),
    do: {:error, :callback_limit, "invalid callback request"}

  defp dispatch_granted(state, id, name, argument) do
    case Map.fetch(state.limits.callbacks, name) do
      {:ok, callback} -> start_callback(state, id, callback, argument)
      :error -> reject_request(state, id)
    end
  end

  defp reject_request(state, id) do
    case encode_error(
           id,
           "capability_denied",
           "Callback is not granted",
           state.limits.max_callback_output
         ) do
      {:fatal, message} ->
        {:error, :callback_limit, message}

      result ->
        send(state.parent, {:callback_reply, state.token, Jason.encode!([result])})
        {:ok, state}
    end
  end

  defp admitted?(state, id) do
    id <= 1024 && !MapSet.member?(state.seen, id) &&
      MapSet.size(state.seen) < state.limits.max_callback_calls &&
      map_size(state.jobs) < state.limits.max_callback_concurrency
  end

  defp valid_payload?(state, name, argument) do
    byte_size(argument) <= state.limits.max_callback_input && byte_size(name) in 1..128 &&
      String.valid?(name)
  end

  defp start_callback(state, id, callback, argument) do
    parent = self()
    deadline = min(state.limits.deadline, now() + state.limits.callback_timeout)
    token = state.token
    max_output = state.limits.max_callback_output

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          if now() < deadline do
            result = invoke(callback, argument, %{deadline: deadline}, id, max_output)
            send(parent, {:result, token, self(), result})
          else
            send(parent, {:callback_timeout, self()})
          end
        end,
        [:link, :monitor]
      )

    timer = Process.send_after(self(), {:callback_timeout, pid}, max(0, deadline - now()))
    job = %{id: id, ref: ref, timer: timer, result: nil}
    {:ok, %{state | jobs: Map.put(state.jobs, pid, job)}}
  end

  defp invoke(callback, argument, context, id, max_output) do
    encode_result(callback.(argument, context), id, max_output)
  rescue
    _ -> encode_error(id, "callback_failed", "Host callback failed", max_output)
  catch
    _, _ -> encode_error(id, "callback_failed", "Host callback failed", max_output)
  end

  defp encode_result({:ok, value}, id, max_output) do
    with true <- json?(value), {:ok, bytes} <- Jason.encode_to_iodata(value) do
      if IO.iodata_length(bytes) <= max_output,
        do: %{id: id, ok: true, value: IO.iodata_to_binary(bytes)},
        else: {:fatal, "callback result exceeds max_callback_output"}
    else
      _ ->
        encode_error(
          id,
          "callback_failed",
          "Host callback returned an invalid result",
          max_output
        )
    end
  end

  defp encode_result({:error, %{"code" => code, "message" => message}}, id, max_output)
       when is_binary(code) and is_binary(message),
       do: encode_error(id, code, message, max_output)

  defp encode_result(_, id, max_output),
    do:
      encode_error(id, "callback_failed", "Host callback returned an invalid result", max_output)

  defp encode_error(id, code, message, max_output) do
    if byte_size(Jason.encode!(%{code: code, message: message})) <= max_output,
      do: %{id: id, ok: false, code: code, message: message},
      else: {:fatal, "callback error exceeds max_callback_output"}
  end

  defp json?(nil), do: true
  defp json?(value) when is_boolean(value) or is_number(value) or is_binary(value), do: true
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)

  defp json?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, value} -> is_binary(key) && json?(value) end)

  defp json?(_), do: false

  defp fail(state, kind, message) do
    send(state.parent, {:callback_error, state.token, kind, message})
    cleanup(state)
  end

  defp cleanup(state) do
    Enum.each(state.jobs, fn {pid, job} ->
      Process.cancel_timer(job.timer)
      Process.exit(pid, :kill)
    end)

    Enum.each(state.jobs, fn {pid, job} ->
      receive do
        {:DOWN, ref, :process, ^pid, _} when ref == job.ref -> :ok
      end
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
