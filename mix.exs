defmodule Javex.MixProject do
  use Mix.Project

  @version "0.1.5"
  @source_url "https://github.com/tuist/javex"

  def project do
    [
      app: :javex,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      # NIF replacements do not execute their Elixir fallback bodies.
      # Rust contracts run separately with cargo test.
      test_coverage: [ignore_modules: [Javex.Native]],
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:rustler_precompiled, "~> 0.8"},
      {:rustler, "~> 0.36", optional: true},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:quokka, "~> 2.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev, :prod], runtime: false}
    ]
  end

  defp description do
    "Compile JavaScript to WebAssembly with Javy and run it on wasmtime, " <>
      "with dynamic linking by default for tiny modules and fast cold starts."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(
        lib
        native/javex_nif/src
        native/javex_nif/Cargo.toml
        native/javex_nif/Cargo.lock
        native/javex_nif/.cargo
        native/javex_plugin/src
        native/javex_plugin/Cargo.toml
        native/javex_plugin/Cargo.lock
        native/javex_plugin/.cargo
        native/javex_plugin/build
        priv/javy_plugin.wasm
        checksum-*.exs
        mix.exs
        README.md
        LICENSE
        CHANGELOG.md
        .formatter.exs
      )
    ]
  end

  defp docs do
    [
      main: "Javex",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end
end
