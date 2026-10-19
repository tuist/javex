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
    binaries: ["javex_worker"],
    base_url: "https://github.com/tuist/javex/releases/download/v#{version}",
    force_build: System.get_env("JAVEX_BUILD") in ["1", "true"],
    version: version,
    nif_versions: ["2.16"],
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      aarch64-unknown-linux-gnu
      x86_64-unknown-linux-gnu
    )

  def compile(_plugin, _source, _mode, _opts, _control), do: err()
  def runtime_new(_plugin, _limits), do: err()
  def runtime_stats(_runtime), do: err()
  def control_new(_timeout_ms), do: err()
  def cancel(_control), do: err()
  def run_start(_runtime, _wasm, _input, _opts, _control), do: err()
  def run_step(_execution, _completion), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
