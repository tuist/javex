defmodule Javex.Module do
  @moduledoc """
  A compiled Javex module.

  Wraps the Wasm bytes produced by Javy together with metadata:

    * `:mode` - `:dynamic` or `:static`.
    * `:provider_hash` - SHA-256 of the provider plugin the module was
      linked against. `Javex.Runtime` uses this to reject a module if the
      runtime's provider does not match (dynamic mode only).

  Modules are plain data. If you need to persist one,
  `:erlang.term_to_binary/1` round-trips the struct with zero ceremony.
  """

  alias Javex.{CompileError, Native, Options}

  @type mode :: :dynamic | :static

  @type t :: %__MODULE__{
          bytes: binary(),
          mode: mode(),
          provider_hash: binary() | nil
        }

  @enforce_keys [:bytes, :mode]
  defstruct [:bytes, :mode, :provider_hash]

  @doc false
  @spec compile(String.t(), keyword()) :: {:ok, t()} | {:error, CompileError.t()}
  def compile(source, opts) do
    with {:ok, limits} <- Options.compile(opts),
         :ok <- source_size(source, limits.max_input) do
      mode = Keyword.get(opts, :mode, :dynamic)

      result =
        if runtime = Keyword.get(opts, :runtime) do
          Javex.Runtime.compile(runtime, source, mode, opts, limits)
        else
          compile_with_deadline(source, mode, opts, limits)
        end

      case result do
        {:ok, {bytes, provider_hash}} ->
          {:ok,
           %__MODULE__{
             bytes: bytes,
             mode: mode,
             provider_hash: if(mode == :dynamic, do: provider_hash)
           }}

        {:error, reason} ->
          compile_error(reason)
      end
    else
      {:error, reason} -> compile_error(reason)
    end
  end

  defp source_size(source, max) do
    if byte_size(source) <= max, do: :ok, else: {:error, "source limit exceeded"}
  end

  defp compile_with_deadline(source, mode, opts, limits) do
    caller = self()
    reply = :erlang.alias()

    {guardian, monitor} =
      spawn_monitor(fn ->
        caller_monitor = Process.monitor(caller)
        control = Native.control_new(limits.timeout)
        guardian = self()

        {worker, worker_monitor} =
          spawn_monitor(fn ->
            result =
              try do
                Native.compile(
                  Keyword.get(opts, :plugin) || Javex.Plugin.bytes!(),
                  source,
                  mode,
                  Options.native(limits, mode),
                  control
                )
              rescue
                error -> {:error, Exception.message(error)}
              end

            send(guardian, {:compiled, result})
          end)

        receive do
          {:compiled, result} ->
            send(reply, {reply, result})

          {:DOWN, ^caller_monitor, :process, _, _} ->
            :ok

          {:DOWN, ^worker_monitor, :process, _, _} ->
            send(reply, {reply, {:error, "compiler worker stopped"}})
        after
          limits.timeout -> send(reply, {reply, {:error, "compilation timed out"}})
        end

        Native.cancel(control)
        Process.exit(worker, :kill)
      end)

    try do
      receive do
        {^reply, result} -> result
        {:DOWN, ^monitor, :process, ^guardian, _} -> {:error, "compiler coordinator stopped"}
      end
    after
      :erlang.unalias(reply)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp compile_error(%_{} = error), do: {:error, %CompileError{message: Exception.message(error)}}
  defp compile_error({_kind, message}), do: compile_error(message)
  defp compile_error(message), do: {:error, %CompileError{message: to_string(message)}}
end
