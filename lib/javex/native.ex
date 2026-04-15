defmodule Javex.Native do
  @moduledoc false

  # Rustler NIF boundary. All functions are private to Javex internals;
  # user-facing API lives in `Javex`, `Javex.Module`, and `Javex.Runtime`.
  #
  # The NIF is distributed as a precompiled artifact built in CI for all
  # supported targets, so consumers of Javex do not need a Rust toolchain
  # installed. Set `JAVEX_BUILD=1` to force a local source build.

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :javex,
    crate: "javex_nif",
    base_url: "https://github.com/tuist/javex/releases/download/v#{version}",
    force_build: System.get_env("JAVEX_BUILD") in ["1", "true"],
    version: version,
    nif_versions: ["2.15", "2.16"],
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      aarch64-unknown-linux-gnu
      x86_64-unknown-linux-gnu
    )

  def compile(_plugin, _source, _mode), do: err()
  def runtime_new(_plugin), do: err()
  def module_precompile(_runtime, _wasm_bytes), do: err()
  def run(_runtime, _precompiled, _input, _opts), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
