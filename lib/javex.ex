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
  @type json ::
          %{optional(String.t()) => json()} | [json()] | String.t() | number() | boolean() | nil
  @type callback ::
          (json(), %{deadline: integer()} ->
             {:ok, json()} | {:error, %{required(String.t()) => String.t()}})

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
    * `:callbacks` - per-run map of UTF-8 names to arity-2 Elixir functions.
      Defaults to `%{}` (no capabilities). See "Host callbacks" below.
    * `:max_callback_calls` - total callback attempts. Default 32; maximum 1024.
      Zero denies all attempts.
    * `:max_callback_concurrency` - outstanding JS host calls. Default 4;
      maximum 1024. Exceeding it fails rather than queueing unbounded work.
    * `:callback_timeout` - milliseconds per callback, including encoding its
      result. Default 1_000; also bounded by the remaining run deadline.
    * `:max_callback_input`, `:max_callback_output` - encoded JSON bytes per
      argument and result/error, separate from stdin/stdout. Defaults 64 KiB
      and 256 KiB; maximum 8 MiB each.

  Limits must be finite non-negative integers; memory, input, module and timeout
  must be positive. Invalid options return an error. Saturated runtimes return
  `:busy`. Caller death cancels execution. These options are controlled by trusted
  host code, not by the JS author.

  The bundled JS environment supports synchronous `Javy.IO`, text encoding,
  Promises and top-level `await`; it does not provide Node, Deno, fetch, timers,
  or external module loading. No host filesystem is preopened. Runtime clocks
  are not deterministic; snapshot-seeded `Math.random` can repeat across instances
  and is not cryptographically secure. `max_memory` is not an OS process/RSS limit. For
  untrusted code, start a Linux runtime with `backend: :isolated` and a finite
  `max_process_memory`: native parsing, compilation and execution then run in
  disposable, killable OS-restricted workers. Also pass that runtime to
  `compile/2`; standalone compilation remains in-process. Host-side JSON
  encoding/decoding is outside the worker's address-space limit.

  ## Host callbacks

  JavaScript calls `await Javex.Host.call("name", argument)`. `Promise.all`
  runs independent callbacks concurrently on both backends. Registration grants
  only that name for this run; callbacks are never inherited from other runs.
  Names are non-empty strings of at most 128 UTF-8 bytes, with at most 128 grants.

  A callback receives one decoded JSON value and `%{deadline: deadline}`, an
  absolute `System.monotonic_time(:millisecond)` deadline. It returns
  `{:ok, json}` or `{:error, %{"code" => code, "message" => safe_message}}`.
  Objects must have string keys; structs, tuples, atoms other than booleans/nil,
  and non-JSON values are rejected. Use strings for integers outside JavaScript's
  safe-integer range, and an explicit base64 convention for binary data.

  Declared errors reject the JS Promise with an Error named `HostError` and a
  `code` property. Unknown names reject with `capability_denied`; crashes and
  invalid returns reject with sanitized `callback_failed` errors. A rejection
  propagated to the root module fails the run with `:js_error`. Callback limits
  and callback timeouts terminate the run with `:callback_limit` and
  `:callback_timeout`, even if JS catches an exception. The overall deadline
  remains `:timeout`.

  Await all work that must finish: execution ends when the root module evaluation
  settles, and cancels remaining callbacks before returning. Caller death and
  runtime shutdown cancel callbacks too. Callback code runs in monitored Elixir
  processes, outside the Wasm/process memory limits. Host code must bound HTTP
  bodies while reading, propagate deadlines to its HTTP client, and cancel any
  separately owned work. Cancellation cannot undo external side effects.

  HTTP clients, credentials and destination/method policy belong in callbacks,
  not the guest or Javex core. Never grant an unrestricted HTTP proxy to untrusted
  JS. Custom providers need the Javex resumable ABI to expose `Javex.Host`;
  legacy providers retain their existing synchronous execution behavior.

  ## Examples

      {:ok, %{"sum" => 3}} = Javex.run(mod, %{a: 1, b: 2})
      {:ok, bytes}         = Javex.run(mod, "raw in", encoding: :raw)

      Javex.run(mod, nil,
        callbacks: %{"http.request" => &MyApp.HTTP.request/2}
      )
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
