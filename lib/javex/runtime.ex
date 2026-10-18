defmodule Javex.Runtime do
  @moduledoc """
  Owns a compiled provider and a bounded native-module cache. Each execution
  uses a fresh store and provider instance on a monitored worker, so the server
  remains responsive while JavaScript runs.

  Add `Javex.Runtime` to your supervision tree. Use `:name` and `runtime: name`
  for multiple runtimes. Options named `:default_timeout`, `:default_fuel`,
  `:default_max_memory`, `:default_max_input`, `:default_max_output`,
  `:default_max_stderr`, and `:default_max_module` supply the defaults documented
  by `Javex.run/3`. These are defaults, not authorization ceilings; only trusted
  host code should choose options.

  `:max_concurrency` defaults to 4. Saturation returns `:busy` rather than
  accumulating an unbounded queue. Calls cancelled or timed out retain their
  slot until native work actually stops. `:max_cached_modules` defaults to 64
  and `:max_cache_bytes` to 64 MiB of compiled images; zero disables caching.

  `:backend` defaults to `:in_process`. For untrusted code on Linux, select
  `:isolated`: compilation with `runtime: name` and execution run in disposable
  OS-restricted workers. `:max_process_memory` caps each execution child's
  address space (default 512 MiB), including native parsing and JIT allocations.
  Workers are killed and reaped on cancellation or deadline. There is no
  cross-call native cache in this mode. It requires Linux with `close_range`
  and seccomp TSYNC; unavailable protections fail closed, never fall back.
  Compilations using this runtime share its admission capacity with executions.

  `:plugin_path` selects a trusted, initialized Javy provider instead of the
  bundled provider. Compile against it with `Javex.compile(js, runtime: name)`.
  """

  use GenServer

  alias Javex.{IncompatibleProviderError, Isolated, Module, Native, Options, Plugin, RuntimeError}

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def run(server, %Module{} = mod, input, opts) do
    GenServer.call(server, {:run, mod, input, opts, now()}, :infinity)
  catch
    :exit, _reason -> error(:runtime_down, "runtime is not available")
  end

  @doc false
  def compile(server, source, mode, opts, limits) do
    GenServer.call(server, {:compile, source, mode, opts, limits, now()}, :infinity)
  catch
    :exit, _reason -> error(:runtime_down, "compiler runtime is not available")
  end

  @doc "Returns the trusted provider bytes used by this runtime."
  def plugin_bytes(server \\ __MODULE__), do: GenServer.call(server, :plugin_bytes)

  @doc "Returns active execution count and bounded compiled-image cache statistics."
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    with {:ok, defaults} <- Options.runtime(opts),
         {:ok, plugin} <- File.read(Keyword.get(opts, :plugin_path, Plugin.path())),
         backend = Keyword.get(opts, :backend, :in_process),
         {:ok, native} <- new_native(backend, plugin, opts) do
      {:ok,
       %{
         native: native,
         backend: backend,
         max_process_memory: Keyword.get(opts, :max_process_memory, 512 * 1024 * 1024),
         plugin: plugin,
         plugin_hash: :crypto.hash(:sha256, plugin),
         defaults: defaults,
         max_concurrency: Keyword.get(opts, :max_concurrency, 4),
         jobs: %{}
       }}
    else
      {:error, reason} -> {:stop, {:plugin_load_failed, reason}}
    end
  end

  @impl true
  def handle_call(:plugin_bytes, _from, state), do: {:reply, state.plugin, state}

  def handle_call(:stats, _from, state) do
    cache =
      if state.backend == :isolated,
        do: %{cached_modules: 0, cache_bytes: 0, cache_hits: 0},
        else: Native.runtime_stats(state.native)

    {:reply, Map.put(cache, :running, map_size(state.jobs)), state}
  end

  def handle_call({:run, mod, input, opts, started}, from, state) do
    with {:ok, limits} <- Options.run(opts, state.defaults),
         :ok <- check_module(mod, state, limits) do
      start_job(from, started, limits.timeout, state, fn control, server, remaining ->
        execute(state, mod, input, %{limits | timeout: remaining}, control, server)
      end)
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:compile, source, mode, opts, limits, started}, from, state) do
    start_job(from, started, limits.timeout, state, fn control, server, remaining ->
      plugin = Keyword.get(opts, :plugin) || state.plugin
      limits = %{limits | timeout: remaining}

      case state.backend do
        :isolated ->
          Isolated.compile(plugin, source, mode, limits, state.max_process_memory, server)

        :in_process ->
          Native.compile(plugin, source, mode, Options.native(limits, mode), control)
      end
    end)
  end

  @impl true
  def handle_info({:result, pid, result}, state) do
    case Map.pop(state.jobs, pid) do
      {nil, _} ->
        {:noreply, state}

      {job, jobs} ->
        cleanup(job)

        result =
          if now() >= job.deadline, do: error(:timeout, "execution timed out"), else: result

        if job.from, do: GenServer.reply(job.from, result)
        {:noreply, %{state | jobs: jobs}}
    end
  end

  def handle_info({:timeout, pid}, state) do
    case Map.fetch(state.jobs, pid) do
      {:ok, job} ->
        cancel(pid, job)
        if job.from, do: GenServer.reply(job.from, error(:timeout, "execution timed out"))
        {:noreply, put_in(state.jobs[pid].from, nil)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.jobs, fn {_pid, job} ->
           job.monitor == ref || job.caller_monitor == ref
         end) do
      nil ->
        {:noreply, state}

      {pid, %{monitor: ^ref} = job} ->
        cleanup(job)
        if job.from, do: GenServer.reply(job.from, error(:trap, "execution worker stopped"))
        {:noreply, %{state | jobs: Map.delete(state.jobs, pid)}}

      {pid, job} ->
        cancel(pid, job)
        {:noreply, put_in(state.jobs[pid].from, nil)}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.jobs, fn {pid, job} -> cancel(pid, job) end)
  end

  defp new_native(:isolated, _plugin, _opts), do: Isolated.available()

  defp new_native(:in_process, plugin, opts) do
    Native.runtime_new(plugin, %{
      max_cache_bytes: Keyword.get(opts, :max_cache_bytes, 64 * 1024 * 1024),
      max_cached_modules: Keyword.get(opts, :max_cached_modules, 64)
    })
  end

  defp start_job(from, started, timeout, state, work) do
    with :ok <- capacity(state),
         remaining = timeout - (now() - started),
         :ok <- remaining_time(remaining) do
      control = if state.backend == :in_process, do: Native.control_new(remaining)
      server = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          result = work.(control, server, remaining)
          send(server, {:result, self(), result})
        end)

      job = %{
        from: from,
        monitor: monitor,
        caller_monitor: Process.monitor(elem(from, 0)),
        timer: Process.send_after(self(), {:timeout, pid}, remaining),
        control: control,
        deadline: started + timeout
      }

      {:noreply, put_in(state.jobs[pid], job)}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp cancel(pid, job) do
    if job.control, do: Native.cancel(job.control)
    send(pid, :cancel)
  end

  defp execute(state, mod, input, limits, control, server) do
    with {:ok, input} <- encode(input, limits),
         {:ok, bytes} <- run_native(state, mod, input, limits, control, server) do
      decode(bytes, limits.encoding)
    else
      {:error, {kind, message}} -> error(kind, message)
      {:error, _} = error -> error
    end
  rescue
    exception -> error(:trap, Exception.message(exception))
  end

  defp run_native(%{backend: :isolated} = state, mod, input, limits, _control, server) do
    Isolated.run(state.plugin, mod, input, limits, state.max_process_memory, server)
  end

  defp run_native(state, mod, input, limits, control, _server) do
    Native.run(state.native, mod.bytes, input, Options.native(limits, mod.mode), control)
  end

  defp encode(input, %{encoding: :raw, max_input: max}) when is_binary(input) do
    if byte_size(input) <= max,
      do: {:ok, input},
      else: error(:input_limit, "input limit exceeded")
  end

  defp encode(_input, %{encoding: :raw}), do: error(:invalid_options, "raw input must be binary")

  defp encode(input, %{max_input: max}) do
    with {:ok, iodata} <- Jason.encode_to_iodata(input) do
      if IO.iodata_length(iodata) <= max,
        do: {:ok, IO.iodata_to_binary(iodata)},
        else: error(:input_limit, "input limit exceeded")
    end
  end

  defp decode(bytes, :raw), do: {:ok, bytes}
  defp decode(<<>>, :json), do: {:ok, nil}
  defp decode(bytes, :json), do: Jason.decode(bytes)

  defp check_module(%Module{bytes: bytes, mode: mode} = mod, state, limits)
       when is_binary(bytes) and mode in [:static, :dynamic] do
    cond do
      byte_size(bytes) > limits.max_module ->
        error(:module_limit, "Wasm module limit exceeded")

      mode == :static || mod.provider_hash == state.plugin_hash ->
        :ok

      true ->
        {:error, %IncompatibleProviderError{expected: state.plugin_hash, got: mod.provider_hash}}
    end
  end

  defp check_module(_mod, _state, _limits), do: error(:invalid_options, "invalid compiled module")

  defp capacity(state) do
    if map_size(state.jobs) < state.max_concurrency,
      do: :ok,
      else: error(:busy, "runtime is at capacity")
  end

  defp remaining_time(remaining) do
    if remaining > 0, do: :ok, else: error(:timeout, "execution timed out before admission")
  end

  defp cleanup(job) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    Process.demonitor(job.caller_monitor, [:flush])
  end

  defp error(kind, message), do: {:error, %RuntimeError{kind: kind, message: message}}
  defp now, do: System.monotonic_time(:millisecond)
end
