defmodule Javex do
  @moduledoc """
  Compile JavaScript to WebAssembly with Javy and run it on wasmtime.

  Javex uses **dynamic linking by default**: the compiled module imports
  QuickJS from a provider compiled once per `Javex.Runtime` and instantiated
  in a fresh store for every call. Dynamic user modules stay tiny.

  ## Quick start

      iex> {:ok, mod} = Javex.compile(~S\"\"\"
      ...> Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify({ sum: 3 })));
      ...> \"\"\")
      iex> Javex.run(mod, nil)
      {:ok, %{"sum" => 3}}

  Starting a runtime is the consumer's responsibility. Add
  `Javex.Runtime` (or `{Javex.Runtime, opts}`) to your application's
  supervision tree. The default registered name is `Javex.Runtime`,
  which is what `run/3` looks for unless you pass `:runtime`.

  `compile/2` does **not** need a running runtime: it reads the bundled
  provider plugin directly from `priv/` and is safe to call from one-off
  scripts.
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

    * `:runtime` - a `Javex.Runtime` server (pid, name, or `{:via, ...}`)
      to source the provider plugin and compilation backend from. Pass an
      isolated runtime here to isolate compilation as well as execution.
      Required when you intend to
      run the module on a runtime started with a custom `:plugin_path`,
      otherwise the compiled module will be hashed against the bundled
      plugin and rejected as incompatible at run time.

    * `:plugin` - raw plugin bytes. Advanced escape hatch when you have
      the plugin in hand already and do not want Javex to source it
      through a runtime or the bundled file. Providers must be trusted and
      already initialized, like the bundled Javy provider.

    * `:timeout`, `:fuel`, `:max_memory`, `:max_stderr`, `:max_module` -
      finite compilation budgets, with the same defaults as `run/3`.
    * `:max_source` - maximum UTF-8 source bytes. Default 1 MiB.

  When neither `:runtime` nor `:plugin` is given, the bundled
  `priv/javy_plugin.wasm` is used.

  ## Examples

      {:ok, mod} = Javex.compile(js)
      {:ok, mod} = Javex.compile(js, runtime: :strict_runtime)
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

    * `:runtime` - runtime to execute on. Defaults to `Javex.Runtime`,
      which the consumer starts explicitly.
    * `:encoding` - `:json` (default) or `:raw`.
    * `:timeout` - caller deadline in milliseconds, including admission,
      encoding, compilation, execution and decoding. Default `5_000`.
    * `:fuel` - wasmtime instruction budget. Default `100_000_000`.
    * `:max_memory` - guest linear-memory cap in bytes. Default 64 MiB.
    * `:max_input`, `:max_output` - encoded input and stdout byte caps.
      Default 1 MiB each.
    * `:max_stderr` - diagnostic byte cap. Default 64 KiB.
    * `:max_module` - input Wasm byte cap. Default 8 MiB.
    * `:env` - explicit WASI environment; host environment is never inherited.
    * `:callbacks` - per-run map of UTF-8 names (1–128 bytes) to Elixir functions
      of arity 2. Defaults to `%{}` (no host access). See "Host callbacks" below.
    * `:callback_timeout` - maximum time per callback in milliseconds, also
      bounded by the run deadline. Default `1_000`.
    * `:max_callback_calls` - maximum callback attempts per run. Default `32`;
      zero disables callbacks, including denied attempts.
    * `:max_callback_input` - maximum encoded JSON request bytes per callback,
      including the name and argument envelope. Default 64 KiB.
    * `:max_callback_output` - maximum encoded JSON result or declared error
      bytes per callback, excluding the transport envelope. Default 256 KiB.
      Callback byte budgets must be positive and at most 64 MiB each.

  Limits must be finite non-negative integers; memory, input, module and timeout
  must be positive. Invalid options return an error. Saturated runtimes return
  `:busy`. Caller death cancels execution. These options are controlled by trusted
  host code, not by the JS author.

  The bundled JS environment supports synchronous `Javy.IO` and text encoding;
  it does not provide Node, Deno, fetch, timers, external module loading, or a
  Promise event loop. No host filesystem is preopened. Clocks and randomness
  are not deterministic. `max_memory` is not an OS process/RSS limit. For
  untrusted code, start a Linux runtime with `backend: :isolated` and a finite
  `max_process_memory`: native parsing, compilation and execution then run in
  disposable, killable OS-restricted workers. Also pass that runtime to
  `compile/2`; standalone compilation remains in-process. Host-side JSON
  encoding/decoding is outside the worker's address-space limit.

  ## Host callbacks

  JavaScript compiled with Javex can call `Javex.Host.call(name, argument)`.
  Only callbacks supplied to this execution are accessible, on either backend:

      callbacks = %{
        "lookup" => fn %{"id" => id}, %{deadline: deadline} ->
          MyApp.lookup(id, deadline: deadline)
        end
      }

      Javex.run(mod, input, callbacks: callbacks)

  Each function receives a JSON argument and `%{deadline: deadline}`, where
  `deadline` is an absolute `System.monotonic_time(:millisecond)` deadline.
  It returns `{:ok, value}` or
  `{:error, %{"code" => "unavailable", "message" => "Try later"}}`.
  Values must be JSON-compatible: string-keyed maps, lists, UTF-8 strings,
  numbers, booleans or `nil`; no structs or other atoms. JavaScript numbers
  have their usual safe-integer/precision limits. Use explicit base64 for bytes.

  Calls are synchronous: JavaScript waits for Elixir, without a Promise loop.
  Declared errors throw a catchable `HostError` with `code` and `message`.
  Unknown names throw `callback_denied`; exceptions, exits, throws and invalid
  results become sanitized `callback_failed` errors. Uncaught errors fail the
  run as `:js_error`. Callback quota violations and callback deadlines terminate
  the run as `:callback_limit` and `:callback_timeout`; JS cannot catch them.

  Callbacks execute in separate monitored Elixir processes, outside the runtime
  GenServer. Their execution and JSON encoding count toward the run deadline.
  Timeout, caller death and runtime shutdown stop the callback process; admission
  is retained until it and native execution stop. Work independently spawned by
  a callback needs its own cancellation. External effects cannot be rolled back.
  Fuel and guest/process memory limits do not meter Elixir code or HTTP buffers.

  For HTTP, register an application callback using your HTTP client. Keep
  credentials in host code, allowlist destinations/methods, validate redirects
  and resolved addresses, and bound reads/decompression before buffering bodies.
  No networking is enabled inside the isolated worker. See the README example.
  Callbacks do not make guest-selected Elixir module/function names callable.
  Persisted modules compiled before this API must be recompiled to use it.

  ## Examples

      {:ok, %{"sum" => 3}} = Javex.run(mod, %{a: 1, b: 2})
      {:ok, bytes}         = Javex.run(mod, "raw in", encoding: :raw)
  """
  @spec run(Module.t(), input(), keyword()) :: {:ok, output()} | {:error, term()}
  def run(%Module{} = mod, input, opts \\ []) do
    if Keyword.keyword?(opts) do
      runtime = Keyword.get(opts, :runtime, Runtime)
      Runtime.run(runtime, mod, input, opts)
    else
      {:error,
       %Javex.RuntimeError{kind: :invalid_options, message: "options must be a keyword list"}}
    end
  end
end
