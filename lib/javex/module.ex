defmodule Javex.Module do
  @moduledoc """
  A compiled Javex module.

  Wraps the Wasm bytes produced by Javy together with metadata:

    * `:mode` - `:dynamic` or `:static`.
    * `:provider_hash` - SHA-256 of the provider plugin the module was
      linked against. `Javex.Runtime` uses this to reject a module if the
      runtime's provider does not match (dynamic mode only).

  Modules are plain data and can be written to disk via `write/2` and
  loaded via `read/1`. Persisted modules use a small CBOR-free custom
  envelope so metadata survives the round-trip.
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

  @magic "JVXM"
  @format_version 1

  @doc false
  @spec compile(String.t(), keyword()) :: {:ok, t()} | {:error, CompileError.t()}
  def compile(source, opts) do
    mode = Keyword.get(opts, :mode, :dynamic)

    plugin =
      case mode do
        :dynamic -> Javex.Plugin.bytes!()
        :static -> <<>>
      end

    case Native.compile(plugin, source, mode) do
      {:ok, {bytes, provider_hash}} ->
        {:ok, %__MODULE__{bytes: bytes, mode: mode, provider_hash: provider_hash}}

      {:error, reason} ->
        {:error, %CompileError{message: to_string(reason)}}
    end
  end

  @doc """
  Write a compiled module to disk.

  The written file is *not* a bare `.wasm`. It contains a small header
  describing the linking mode and provider hash so that it can be safely
  reloaded on a different machine. Use `raw_wasm/1` if you want the plain
  Wasm bytes to run with another tool.
  """
  @spec write(t(), Path.t()) :: :ok | {:error, File.posix()}
  def write(%__MODULE__{} = mod, path) do
    File.write(path, encode(mod))
  end

  @doc """
  Read a compiled module from disk.
  """
  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    with {:ok, binary} <- File.read(path) do
      decode(binary)
    end
  end

  @doc """
  Return the raw Wasm bytes without any Javex envelope.

  Useful when embedding the module in other wasmtime-based tooling.
  """
  @spec raw_wasm(t()) :: binary()
  def raw_wasm(%__MODULE__{bytes: bytes}), do: bytes

  defp encode(%__MODULE__{bytes: bytes, mode: mode, provider_hash: hash}) do
    mode_byte =
      case mode do
        :dynamic -> 1
        :static -> 2
      end

    hash = hash || <<>>
    hash_len = byte_size(hash)
    bytes_len = byte_size(bytes)

    <<@magic::binary, @format_version::8, mode_byte::8, hash_len::8, hash::binary,
      bytes_len::32-big, bytes::binary>>
  end

  defp decode(<<@magic, @format_version::8, mode_byte::8, hash_len::8, rest::binary>>) do
    <<hash::binary-size(hash_len), bytes_len::32-big, bytes::binary-size(bytes_len)>> = rest

    mode =
      case mode_byte do
        1 -> :dynamic
        2 -> :static
      end

    {:ok,
     %__MODULE__{
       bytes: bytes,
       mode: mode,
       provider_hash: if(hash == <<>>, do: nil, else: hash)
     }}
  end

  defp decode(_), do: {:error, :invalid_module_file}
end
