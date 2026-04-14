defmodule Javex.Runtime do
  @moduledoc """
  A wasmtime runtime with the Javy provider plugin preloaded.

  The application starts one `Javex.Runtime` under its supervisor by
  default, registered under the name `Javex.Runtime`. You can start
  additional runtimes with different resource limits:

      {:ok, strict} =
        Javex.Runtime.start_link(
          name: :strict_runtime,
          default_fuel: 1_000_000,
          default_max_memory: 8 * 1024 * 1024
        )

      Javex.run(mod, input, runtime: :strict_runtime)

  A runtime owns a wasmtime `Engine`, an instantiated provider plugin,
  and a cache of precompiled user modules (indexed by content hash).
  """

  use GenServer

  alias Javex.{IncompatibleProviderError, Module, Native, RuntimeError}

  @plugin_priv "javy_plugin.wasm"

  ## Public API

  @doc """
  Start a runtime.

  ## Options

    * `:name` - registered name. Defaults to `Javex.Runtime`.
    * `:plugin_path` - override the bundled Javy plugin.
    * `:default_fuel` - fuel budget used by `run/4` when the caller does
      not specify one.
    * `:default_max_memory` - memory cap in bytes.
    * `:default_timeout` - wall-clock timeout in milliseconds. Default
      `5_000`.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def run(server, %Module{} = mod, input, opts) do
    GenServer.call(server, {:run, mod, input, opts}, call_timeout(opts))
  end

  @doc """
  Return the bytes of the Javy provider plugin this runtime was built
  with. Used by `Javex.Module.compile/2` in dynamic mode so the compiled
  module is linked against exactly the provider this runtime hosts.
  """
  @spec plugin_bytes(GenServer.server()) :: binary()
  def plugin_bytes(server \\ __MODULE__) do
    GenServer.call(server, :plugin_bytes)
  end

  ## GenServer

  @impl true
  def init(opts) do
    plugin_path = Keyword.get(opts, :plugin_path, default_plugin_path())

    with {:ok, plugin} <- File.read(plugin_path),
         {:ok, native} <- Native.runtime_new(plugin) do
      state = %{
        native: native,
        plugin: plugin,
        plugin_hash: :crypto.hash(:sha256, plugin),
        precompiled: %{},
        default_fuel: Keyword.get(opts, :default_fuel),
        default_max_memory: Keyword.get(opts, :default_max_memory),
        default_timeout: Keyword.get(opts, :default_timeout, 5_000)
      }

      {:ok, state}
    else
      {:error, reason} -> {:stop, {:plugin_load_failed, reason}}
    end
  end

  @impl true
  def handle_call(:plugin_bytes, _from, state) do
    {:reply, state.plugin, state}
  end

  @impl true
  def handle_call({:run, mod, input, opts}, _from, state) do
    with :ok <- check_provider(mod, state),
         {:ok, precompiled, state} <- fetch_or_precompile(mod, state),
         {:ok, raw_input} <- encode_input(input, opts),
         native_opts = build_opts(opts, state),
         {:ok, raw_output} <- Native.run(state.native, precompiled, raw_input, native_opts),
         {:ok, decoded} <- decode_output(raw_output, opts) do
      {:reply, {:ok, decoded}, state}
    else
      {:error, %_{} = err} -> {:reply, {:error, err}, state}
      {:error, reason} -> {:reply, {:error, translate(reason)}, state}
    end
  end

  ## Helpers

  defp default_plugin_path do
    Application.app_dir(:javex, ["priv", @plugin_priv])
  end

  defp check_provider(%Module{mode: :static}, _state), do: :ok

  defp check_provider(%Module{mode: :dynamic, provider_hash: hash}, %{plugin_hash: hash}),
    do: :ok

  defp check_provider(%Module{mode: :dynamic, provider_hash: got}, %{plugin_hash: expected}) do
    {:error,
     %IncompatibleProviderError{
       expected: expected,
       got: got
     }}
  end

  defp fetch_or_precompile(%Module{bytes: bytes} = mod, state) do
    key = :crypto.hash(:sha256, bytes)

    case Map.fetch(state.precompiled, key) do
      {:ok, precompiled} ->
        {:ok, precompiled, state}

      :error ->
        case Native.module_precompile(state.native, mod.bytes) do
          {:ok, precompiled} ->
            {:ok, precompiled,
             %{state | precompiled: Map.put(state.precompiled, key, precompiled)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp encode_input(input, opts) do
    case Keyword.get(opts, :encoding, :json) do
      :json -> Jason.encode(input)
      :raw when is_binary(input) -> {:ok, input}
      :raw -> {:error, :raw_input_must_be_binary}
    end
  end

  defp decode_output(<<>>, _opts), do: {:ok, nil}

  defp decode_output(bytes, opts) do
    case Keyword.get(opts, :encoding, :json) do
      :json -> Jason.decode(bytes)
      :raw -> {:ok, bytes}
    end
  end

  defp build_opts(opts, state) do
    %{
      timeout_ms: Keyword.get(opts, :timeout, state.default_timeout),
      fuel: Keyword.get(opts, :fuel, state.default_fuel),
      max_memory: Keyword.get(opts, :max_memory, state.default_max_memory),
      env: Keyword.get(opts, :env, [])
    }
  end

  defp call_timeout(opts) do
    case Keyword.get(opts, :timeout) do
      nil -> 10_000
      ms when is_integer(ms) -> ms + 2_000
    end
  end

  defp translate(:timeout), do: %RuntimeError{kind: :timeout, message: "execution timed out"}

  defp translate(:fuel_exhausted),
    do: %RuntimeError{kind: :fuel_exhausted, message: "fuel exhausted"}

  defp translate(:oom), do: %RuntimeError{kind: :oom, message: "memory limit exceeded"}
  defp translate({:js_error, message}), do: %RuntimeError{kind: :js_error, message: message}
  defp translate({:trap, message}), do: %RuntimeError{kind: :trap, message: message}
  defp translate(other), do: %RuntimeError{kind: :unknown, message: inspect(other)}
end
