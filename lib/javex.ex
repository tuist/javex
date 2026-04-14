defmodule Javex do
  @moduledoc """
  Compile JavaScript to WebAssembly with Javy and run it on wasmtime.

  Javex uses **dynamic linking by default**: the compiled module imports
  QuickJS from a shared provider plugin that is instantiated once per
  `Javex.Runtime`. That keeps each compiled module tiny (a few KB) and
  makes cold starts fast enough to spin up a fresh instance per call.

  ## Quick start

      iex> {:ok, mod} = Javex.compile(~S\"\"\"
      ...> const input = JSON.parse(readInput());
      ...> writeOutput(JSON.stringify({ sum: input.a + input.b }));
      ...> \"\"\")
      iex> Javex.run(mod, %{a: 1, b: 2})
      {:ok, %{"sum" => 3}}

  The default runtime is started automatically under the `Javex.Application`
  supervisor. For custom fuel or memory limits, start your own with
  `Javex.Runtime.start_link/1`.
  """

  alias Javex.{Module, Runtime}

  @type input :: map() | list() | binary() | number() | boolean() | nil
  @type output :: map() | list() | binary() | number() | boolean() | nil

  @doc """
  Compile a JavaScript source string into a `Javex.Module`.

  ## Options

    * `:mode` - `:dynamic` (default) or `:static`. Dynamic modules import
      QuickJS from the provider plugin and are tiny. Static modules embed
      QuickJS and can run without a runtime that has the plugin loaded,
      at the cost of ~1MB per module and slower cold starts.

  ## Examples

      {:ok, mod} = Javex.compile("writeOutput('hello')")
  """
  @spec compile(String.t(), keyword()) :: {:ok, Module.t()} | {:error, term()}
  def compile(source, opts \\ []) when is_binary(source) do
    Module.compile(source, opts)
  end

  @doc """
  Run a compiled module with the given input.

  The default encoding is `:json`: `input` is JSON-encoded and written to the
  module's stdin, and stdout is JSON-decoded into the returned term. For raw
  byte I/O, pass `encoding: :raw`.

  ## Options

    * `:runtime` - runtime to execute on. Defaults to the named default
      runtime started by `Javex.Application`.
    * `:encoding` - `:json` (default) or `:raw`.
    * `:timeout` - hard wall-clock timeout in milliseconds. Default `5_000`.
    * `:fuel` - wasmtime fuel budget for the call. Default `nil` (unlimited).
    * `:max_memory` - memory cap in bytes. Default `nil`.
    * `:env` - list of `{key, value}` WASI env vars.

  ## Examples

      {:ok, %{"sum" => 3}} = Javex.run(mod, %{a: 1, b: 2})
      {:ok, bytes}         = Javex.run(mod, "raw in", encoding: :raw)
  """
  @spec run(Module.t(), input(), keyword()) :: {:ok, output()} | {:error, term()}
  def run(%Module{} = mod, input, opts \\ []) do
    runtime = Keyword.get(opts, :runtime, Runtime)
    Runtime.run(runtime, mod, input, opts)
  end
end
