# 🌶 Javex

> Run JavaScript inside your Elixir app, sandboxed in WebAssembly.

[![Hex.pm](https://img.shields.io/hexpm/v/javex.svg)](https://hex.pm/packages/javex)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/tuist/javex/blob/main/LICENSE)
[![CI](https://github.com/tuist/javex/actions/workflows/ci.yml/badge.svg)](https://github.com/tuist/javex/actions/workflows/ci.yml)

Javex compiles JavaScript to WebAssembly with [Javy](https://github.com/bytecodealliance/javy) and runs it on [wasmtime](https://wasmtime.dev/), so you can hand a snippet of user-written JS to a Wasm sandbox and get a typed result back. Each call gets a fresh instance — no shared state, nothing leaks between requests.

## ✨ Why you might want this

- 🧮 **User-defined transforms.** Let your users write small JS expressions to filter, map, or reshape data without giving them shell or BEAM access.
- 🔌 **Webhook / payload mappers.** Accept a JS snippet from a customer and run it on incoming events.
- 🧪 **Custom rules and DSLs** that need real expression power without inventing a parser.
- 🪶 **Small modules.** Dynamic modules import a shared compiled provider instead of embedding QuickJS.
- 🔒 **Bounded by default.** Finite fuel, guest memory, wall-clock, I/O, and cache budgets.

## 🚀 Quick start

In your `mix.exs`:

```elixir
def deps do
  [{:javex, "~> 0.1"}]
end
```

Add a runtime to your supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  Javex.Runtime
]
```

Compile and run:

```elixir
js = ~S"""
Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify({hello: "world"})));
"""

{:ok, mod} = Javex.compile(js)
{:ok, %{"hello" => "world"}} = Javex.run(mod, nil)
```

> 💡 **Reading input** in your JS requires a small stdin helper — see [Javy's README](https://github.com/bytecodealliance/javy#example) for the canonical `readInput()` / `writeOutput()` snippet to drop at the top of your script.

## ⚙️ The bits you'll reach for

| You want to… | Use |
| --- | --- |
| Compile a JS snippet | `Javex.compile/2` |
| Run a compiled module with JSON I/O | `Javex.run(mod, input)` |
| Run with raw bytes | `Javex.run(mod, bytes, encoding: :raw)` |
| Grant a host capability | `Javex.run(mod, input, callbacks: %{"name" => &MyApp.callback/2})` |
| Cap fuel, memory, or timeout | `Javex.run(mod, input, fuel: …, max_memory: …, timeout: …)` |
| Set runtime defaults | `Javex.Runtime.start_link(name: :strict, default_fuel: …, default_max_memory: …)` |
| Inspect active calls and cache usage | `Javex.Runtime.stats()` |

Persisting compiled modules? `%Javex.Module{}` is a plain struct — `:erlang.term_to_binary/1` round-trips it, no helper needed.

## Asynchronous host callbacks

`Javex.Host.call(name, argument)` returns a real Promise. Top-level `await`,
sequential calls and `Promise.all` work on both backends. Each run grants its own
named callbacks; runtimes never carry grants or credentials across runs.

For example, expose a narrow HTTP capability, not an unrestricted proxy:

```elixir
js = ~S"""
const products = await Promise.all([
  Javex.Host.call("catalog.product", {id: "p123"}),
  Javex.Host.call("catalog.product", {id: "p456"})
]);
Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(products)));
"""

{:ok, mod} = Javex.compile(js, runtime: :untrusted_js)
Javex.run(mod, nil,
  runtime: :untrusted_js,
  callbacks: %{"catalog.product" => &MyApp.Catalog.product/2},
  callback_timeout: 1_500,
  max_callback_calls: 8,
  max_callback_concurrency: 2
)
```

The application supplies `MyApp.Catalog` and its HTTP client. For example, with
Finch installed and a `MyApp.Finch` pool supervised by the application:

```elixir
defmodule MyApp.Catalog do
  def product(%{"id" => id}, %{deadline: deadline}) when is_binary(id) do
    if !Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, id), do: raise("invalid product ID")
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: raise("deadline elapsed")

    # Neither the base URL nor credentials are chosen by JavaScript.
    token = Application.fetch_env!(:my_app, :catalog_token)
    request = Finch.build(:get, "https://catalog.example.com/products/" <> id,
      [{"authorization", "Bearer " <> token}])

    {:ok, response} = Finch.stream(request, MyApp.Finch, %{status: nil, body: ""}, fn
      {:status, status}, acc -> %{acc | status: status}
      {:data, chunk}, acc ->
        if byte_size(acc.body) + byte_size(chunk) > 65_536 or
             System.monotonic_time(:millisecond) >= deadline,
          do: raise("response budget exceeded")
        %{acc | body: acc.body <> chunk}
      _, acc -> acc
    end, pool_timeout: remaining, receive_timeout: remaining)

    {:ok, %{"status" => response.status, "body" => response.body}}
  end
end
```

Finch does not follow redirects automatically. Keep destination, methods,
redirect/DNS policy and credentials in trusted host code. The example bounds
the body while streaming; checking its size after buffering would be too late.
HTTP is not a Javex dependency, and `fetch` is not installed: the generic bridge
does not implement the browser Request/Response, streaming or AbortSignal APIs.

Callbacks receive one JSON value and an absolute monotonic millisecond deadline.
Return `{:ok, json}` or `{:error, %{"code" => code, "message" => safe_message}}`.
JSON objects use string keys; encode binary bodies explicitly (for example base64),
and use strings for integers beyond JavaScript's safe range. Names are non-empty
UTF-8 strings of at most 128 bytes, with at most 128 grants per run.

Declared errors reject with `HostError` (`code` and `message`). Missing grants use
`capability_denied`; crashes and invalid results use sanitized `callback_failed`
messages. Rejections propagated to the root module fail with `:js_error`.
Callback limits and timeouts terminate the run even if JavaScript catches errors.
Concurrency limits reject excess work rather than building an unbounded queue.

Execution ends when the root module evaluation settles. Await all required work;
detached callbacks are cancelled before a successful run returns. Caller death,
runtime shutdown and deadlines also stop owned callback processes. Host callbacks
run outside the guest's memory and OS limits. Propagate their deadline to your
client and cancel separately owned tasks; killing a callback cannot undo an HTTP
request already received by a server. There is no per-call AbortSignal API yet.

## 🛡 Safety knobs

```elixir
{:ok, output} =
  Javex.run(mod, input,
    timeout: 250,                 # wall-clock ms
    fuel: 5_000_000,              # wasmtime fuel units
    max_memory: 8 * 1024 * 1024   # bytes
  )
```

Compilation and execution return tagged results. JavaScript errors preserve the
original message and source location. JSON encoding/decoding failures return
Jason errors; sandbox failures return `Javex.RuntimeError`:

```elixir
{:error, %Javex.RuntimeError{kind: :timeout}}        # caller deadline elapsed
{:error, %Javex.RuntimeError{kind: :fuel_exhausted}}
{:error, %Javex.RuntimeError{kind: :oom}}
{:error, %Javex.RuntimeError{kind: :js_error}}       # uncaught JS exception
{:error, %Javex.RuntimeError{kind: :output_limit}}
{:error, %Javex.RuntimeError{kind: :busy}}           # admission capacity occupied
```

| Budget | Default |
| --- | --- |
| `timeout` | 5,000 ms, including admission, encoding, JIT, execution, and decoding |
| `fuel` | 100,000,000 Wasmtime fuel units |
| `max_memory` | 64 MiB guest linear memory |
| `max_input`, `max_output` | 1 MiB each |
| `max_stderr` | 64 KiB diagnostics |
| `max_module` | 8 MiB input Wasm |
| `max_callback_calls` | 32 attempts per run; maximum 1,024; zero disables callbacks |
| `max_callback_concurrency` | 4 outstanding calls; maximum 1,024 |
| `callback_timeout` | 1,000 ms per callback, bounded by the run deadline |
| `max_callback_input`, `max_callback_output` | 64 KiB argument / 256 KiB result or error; maximum 8 MiB each |
| Runtime `max_concurrency` | 4 active calls; excess calls return `:busy` |
| Runtime `max_cached_modules`, `max_cache_bytes` | 64 modules / 64 MiB compiled images, LRU eviction |

`Javex.compile/2` also has finite timeout, fuel, memory, diagnostic and module
budgets, plus `max_source` (1 MiB). At most 16 in-process native compilations may
be active globally; saturation returns a compile error. Source must be valid UTF-8.
`mode: :static` embeds the initialized provider; dynamic mode is the default.

Limits must be finite integers. Negative values and `nil` do not disable limits.
Timeout, memory, source, input and module limits must be positive; zero fuel or
output/diagnostic limits are allowed. Runtime `default_*` options are defaults,
**not security ceilings**: trusted host code can override them per call. Keep
options, custom providers, and runtime creation under host control, not under
the JS author's control. Zero cache bytes or module count disables caching.

### Process isolation for untrusted code (Linux)

```elixir
children = [
  {Javex.Runtime,
   name: :untrusted_js,
   backend: :isolated,
   max_process_memory: 512 * 1024 * 1024,
   max_concurrency: 4}
]

# Both calls must select the isolated runtime.
{:ok, mod} = Javex.compile(agent_js, runtime: :untrusted_js)
{:ok, result} = Javex.run(mod, input, runtime: :untrusted_js)
```

Each compilation/execution uses a disposable native child with hard address-space,
CPU, descriptor and core-dump limits. `max_process_memory` defaults to 512 MiB and
includes the child's native parser/JIT allocations, stacks and guest memory. It is
an address-space limit, not an RSS reservation or a cap on the entire BEAM host.
A small trusted supervisor bounds IPC and kills/reaps the child on deadline,
cancellation or a closed BEAM port. Parent-death signals also kill the child if
the supervisor crashes. A child crash returns `:worker_error`; it cannot crash
the BEAM through a NIF call.

Before reading code, the child clears inherited descriptors, has no inherited
environment, disables privilege gain and installs a seccomp syscall allowlist
across all its threads. Filesystem opens, networking, process/thread creation,
execution, cross-process inspection/signalling, resource-limit changes and io_uring are
not permitted. Only the requested WASI environment is supplied to the guest.
Protections must succeed or the call fails; **there is no in-process fallback**.
This backend requires Linux with `close_range` (5.9+) and seccomp TSYNC enabled
by the host/container policy. macOS supports only `:in_process`.

Compilation with `runtime:` shares that runtime's admission capacity. Standalone
`Javex.compile(js)` remains in-process, even if an isolated runtime is running.
Fresh workers do not share a native cache: isolated cache statistics stay zero,
and cold compilation costs apply on every call. IPC requests/responses have a
64 MiB hard transport cap in addition to the configured byte quotas.

### Sandbox boundary

- Each call has a fresh store and provider instance. No JS globals or input
  survive into the next call. Caller death cancels execution. Timed-out or
  cancelled native work retains its admission slot until it actually stops.
- Only stdin, bounded stdout/stderr and explicitly supplied WASI `env` pairs
  are configured. The host environment is never inherited, no filesystem
  directories are preopened, and no network capability is granted.
- The bundled JavaScript API provides synchronous `Javy.IO`, TextEncoder and
  TextDecoder, standard QuickJS intrinsics, Promises, top-level `await`, and
  explicit `Javex.Host.call` capabilities. It is **not Node or Deno**:
  there is no `fetch`, filesystem/path API, external module loading or timers.
  A root awaiting a Promise with no possible completion reaches the run deadline.
  WASI environment pairs are not a JavaScript `process.env` API.
- Runtime clocks are not deterministic. Snapshot-seeded `Math.random` can repeat
  across instances and is not cryptographically secure; obtain security-sensitive
  randomness from a host callback. The module provider hash checks
  compatibility, not authenticity. Persist only trusted module metadata and
  use `:erlang.binary_to_term(bytes, [:safe])` only for trusted serialized data.
- The default `:in_process` backend is for trusted workloads: native JIT work
  cannot be forcibly interrupted, guest quotas do not bound native RSS, and a
  NIF bug can crash the BEAM. Select `:isolated` for untrusted code. Host-side
  JSON encoding/decoding and IPC buffers remain outside the child's memory
  limit. Bound host input terms and admission; use deployment-level cgroups or
  containers to cap the whole application. Process isolation assumes a trusted
  Linux kernel and does not eliminate kernel vulnerabilities or side channels.

Javex supplies bounded computation and explicitly granted host calls. Workflow persistence, retries,
credentials, tools, permissions and external effects belong in the automation
layer above it. Do not execute agent-generated JS as trusted Elixir host code.

## 🧠 How it works (in 60 seconds)

- Compilation runs the provider's `compile-src` ABI inside a fuel/memory/deadline-limited Wasm store, then emits a small wrapper (or embeds the provider in static mode). No JS runs as native host code.
- In-process runtimes share a Wasmtime engine and one epoch clock thread. Each owns a compiled provider, bounded worker admission, and a bounded native-module cache. Isolated runtimes instead launch fresh OS-restricted workers.
- Every `run/3` creates a fresh Wasmtime `Store` and provider instance. The cache avoids repeat native compilation, including for modules whose execution fails.
- The resumable provider returns control between Promise continuations. Elixir runs callbacks in monitored processes, then resumes the same store with correlated results. I/O waits occupy no dirty NIF scheduler. Isolated workers exchange bounded callback/completion frames; their OS network restrictions remain unchanged.
- The Rust NIF and worker executable ship **precompiled** for macOS (Apple Silicon + Intel) and Linux (aarch64 + x86_64 GNU). The isolated backend is Linux-only. No Rust toolchain required to install.

### Bundled provider provenance

`priv/javy_plugin.wasm` is Javex's custom resumable provider, built from the pinned
Javy 7.0.0 runtime used by [Javy CLI v8.1.1](https://github.com/bytecodealliance/javy/releases/tag/v8.1.1).
It is **not** the upstream default provider. Source, locked dependencies,
build instructions and the versioned ABI are in `native/javex_plugin/`.
Install the mise toolchain, clang/libclang and Javy CLI 8.1.1, then rebuild with:

```sh
bash native/javex_plugin/build.sh
```

Provider changes require compatibility tests and recompilation of dynamic
modules. Custom providers must be trusted, initialized Javy providers supporting
the same `cabi_realloc` / `compile-src` / `invoke` ABI; the namespace alone does
not establish compatibility or trust. Providers without Javex's resumable ABI
retain synchronous execution and do not provide `Javex.Host`.

## Development and verification

```sh
mise install
mix deps.get
JAVEX_BUILD=1 mix test --cover
mix format --check-formatted
JAVEX_BUILD=1 mix credo --strict
cargo fmt --manifest-path native/javex_nif/Cargo.toml --check
cargo clippy --manifest-path native/javex_nif/Cargo.toml --all-targets --locked -- -D warnings
cargo test --manifest-path native/javex_nif/Cargo.toml --release --locked
```

Elixir coverage excludes only the replaced NIF fallback bodies; Rust buffer
contracts are tested separately. CI audits dependencies, and release jobs gate
publication on CI and load/run each packaged NIF on its target platform.

## 📄 License

[MIT](https://github.com/tuist/javex/blob/main/LICENSE).
