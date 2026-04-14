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

  alias Javex.{CompileError, Native}

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
    mode = Keyword.get(opts, :mode, :dynamic)
    plugin = plugin_for(mode, opts)

    case Native.compile(plugin, source, mode) do
      {:ok, {bytes, provider_hash}} ->
        {:ok, %__MODULE__{bytes: bytes, mode: mode, provider_hash: provider_hash}}

      {:error, reason} ->
        {:error, %CompileError{message: to_string(reason)}}
    end
  end

  defp plugin_for(:static, _opts), do: <<>>

  defp plugin_for(:dynamic, opts) do
    cond do
      bytes = Keyword.get(opts, :plugin) -> bytes
      runtime = Keyword.get(opts, :runtime) -> Javex.Runtime.plugin_bytes(runtime)
      true -> Javex.Plugin.bytes!()
    end
  end
end
