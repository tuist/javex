defmodule Javex.Plugin do
  @moduledoc """
  Access to the Javy provider plugin Wasm bundled in `priv/`.

  The bundled plugin is what dynamic-linked `Javex.Module`s import
  QuickJS from. Both `Javex.compile/2` and `Javex.Runtime` read the same
  file, so the provider hash stored on a compiled module matches the
  hash of the plugin the runtime hosts — that invariant powers the
  `Javex.IncompatibleProviderError` compatibility check.
  """

  @plugin_priv "javy_plugin.wasm"

  @doc """
  Absolute path to the bundled plugin on disk.
  """
  @spec path() :: Path.t()
  def path do
    Application.app_dir(:javex, ["priv", @plugin_priv])
  end

  @doc """
  Bundled plugin bytes. Raises if the file is missing, which indicates
  a broken package.
  """
  @spec bytes!() :: binary()
  def bytes! do
    path() |> File.read!()
  end
end
