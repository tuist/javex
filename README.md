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
| Cap fuel, memory, or timeout | `Javex.run(mod, input, fuel: …, max_memory: …, timeout: …)` |
| Set runtime defaults | `Javex.Runtime.start_link(name: :strict, default_fuel: …, default_max_memory: …)` |
| Inspect active calls and cache usage | `Javex.Runtime.stats()` |

Persisting compiled modules? `%Javex.Module{}` is a plain struct — `:erlang.term_to_binary/1` round-trips it, no helper needed.

## 🔌 Elixir callbacks and HTTP

Grant named callbacks **per execution**, on either backend:

```elixir
{:ok, mod} = Javex.compile(~S"""
const response = Javex.Host.call("http.request", {path: "/status"});
Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(response)));
""")

Javex.run(mod, nil,
  callbacks: %{"http.request" => &MyApp.ScriptHTTP.request/2},
  timeout: 5_000,
  callback_timeout: 1_000,
  max_callback_calls: 8,
  max_callback_input: 65_536,
  max_callback_output: 262_144
)
```

Callbacks receive `(argument, %{deadline: absolute_monotonic_milliseconds})` and
return `{:ok, json_value}` or
`{:error, %{"code" => "unavailable", "message" => "Try later"}}`.
Use string-keyed maps, lists, UTF-8 strings, numbers, booleans and `nil`; structs
and other atoms are rejected. JS uses normal JSON/number precision rules; encode
binary explicitly, for example with base64. Callback names are UTF-8 strings of
1–128 bytes. No callbacks are granted by default, and grants never persist.

HTTP belongs in your application. For example, with [Req](https://hexdocs.pm/req)
as an **application dependency** (Javex does not depend on it):

```elixir
defmodule MyApp.ScriptHTTP do
  # Fixed origin and explicit operation: JS cannot choose URLs or credentials.
  def request(%{"path" => "/status"}, %{deadline: deadline}) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)
    token = Application.fetch_env!(:my_app, :service_token)

    into = fn {:data, chunk}, {req, resp} ->
      body = resp.body || ""

      if byte_size(body) + byte_size(chunk) > 65_536 do
        {:halt, {req, Req.Response.put_private(resp, :too_large, true)}}
      else
        {:cont, {req, %{resp | body: body <> chunk}}}
      end
    end

    case Req.get("https://api.example.com/status",
           auth: {:bearer, token},
           redirect: false,
           retry: false,
           compressed: false,
           decode_body: false,
           receive_timeout: remaining,
           into: into
         ) do
      {:ok, response} ->
        if Req.Response.get_private(response, :too_large, false) do
          {:error, %{"code" => "body_limit", "message" => "Response too large"}}
        else
          {:ok, %{"status" => response.status, "body" => response.body}}
        end

      {:error, _} ->
        {:error, %{"code" => "unavailable", "message" => "Service unavailable"}}
    end
  end

  def request(_, _), do: {:error, %{"code" => "denied", "message" => "Operation not allowed"}}
end
```

Calls are synchronous, not `fetch` or promises: JS waits while Elixir performs
the operation. Ordinary HTTP statuses are callback data. Declared errors throw
a catchable JS `HostError` with `code` and `message`; missing grants throw
`callback_denied`. Callback exceptions/exits/invalid results throw a sanitized
`callback_failed`, without host stack traces or exception messages.

Callbacks run in separate monitored Elixir processes. They include JSON encoding
in their deadline and stop on timeout, caller death or runtime shutdown. They do
not block the runtime GenServer or occupy dirty CPU schedulers while waiting.
Cancellation cannot undo external effects, and independently spawned HTTP work
needs its own cancellation. The isolated child still has no network access;
only the host callback performs the request.

Defaults are 32 call attempts, 1,000 ms per callback, 64 KiB per encoded request
(including its name/argument envelope), and 256 KiB per encoded result/error
(excluding transport framing). Byte budgets are positive and at most 64 MiB.
Zero call attempts disables callbacks. These budgets are separate from stdin/
stdout, and callback time also counts toward the run deadline. Exceeding them
terminates the run with `:callback_limit` or `:callback_timeout`, even inside JS
`try/catch`. Fuel and guest/process memory limits do **not** constrain Elixir or
HTTP buffers. Bound response reads/decompression in the HTTP client, not only
after buffering. If allowing guest-selected URLs, enforce SSRF protections for
resolved addresses and every redirect. Keep credentials and safe error messages
in trusted host code. Recompile older persisted modules to use `Javex.Host`.

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
  directories are preopened, and no network capability is granted inside Wasm.
  A private callback channel exposes only explicitly granted Elixir callbacks.
- The bundled JavaScript API provides synchronous `Javy.IO`, TextEncoder and
  TextDecoder, and standard QuickJS intrinsics. It is **not Node or Deno**:
  there is no `fetch`, filesystem/path API, external module loading, timers,
  or Promise event loop. Pending Promise jobs fail rather than running later.
  WASI environment pairs are not a JavaScript `process.env` API.
- Clocks and randomness are not deterministic. The module provider hash checks
  compatibility, not authenticity. Persist only trusted module metadata and
  use `:erlang.binary_to_term(bytes, [:safe])` only for trusted serialized data.
- The default `:in_process` backend is for trusted workloads: native JIT work
  cannot be forcibly interrupted, guest quotas do not bound native RSS, and a
  NIF bug can crash the BEAM. Select `:isolated` for untrusted code. Host-side
  JSON encoding/decoding and IPC buffers remain outside the child's memory
  limit. Bound host input terms and admission; use deployment-level cgroups or
  containers to cap the whole application. Process isolation assumes a trusted
  Linux kernel and does not eliminate kernel vulnerabilities or side channels.

Javex supplies bounded synchronous computation. Workflow persistence, retries,
credentials, tools, permissions and external effects belong in the automation
layer above it. Do not execute agent-generated JS as trusted Elixir host code.

## 🧠 How it works (in 60 seconds)

- Compilation runs the provider's `compile-src` ABI inside a fuel/memory/deadline-limited Wasm store, then emits a small wrapper (or embeds the provider in static mode). No JS runs as native host code.
- In-process runtimes share a Wasmtime engine and one epoch clock thread. Each owns a compiled provider, bounded worker admission, and a bounded native-module cache. Isolated runtimes instead launch fresh OS-restricted workers.
- Every `run/3` creates a fresh Wasmtime `Store` and provider instance. The cache avoids repeat native compilation, including for modules whose execution fails.
- The Rust NIF and worker executable ship **precompiled** for macOS (Apple Silicon + Intel) and Linux (aarch64 + x86_64 GNU). The isolated backend is Linux-only. No Rust toolchain required to install.

### Bundled provider provenance

`priv/javy_plugin.wasm` is Javex's initialized custom provider, built from
`native/javex_plugin` with `javy-plugin-api` 6.0.0 (Javy 7.0.0) and initialized
using the [Javy v8.1.1 CLI](https://github.com/bytecodealliance/javy/releases/tag/v8.1.1).
It retains the standard synchronous Javy environment and adds `Javex.Host.call`
through the private `javex_host_v1` Wasm imports. Its provider namespace is
`javex-plugin-v1`; it is **not** the official default provider binary.

To rebuild on Linux x86_64, install the pinned Rust toolchain, Clang and
libclang development headers, then:

```sh
curl -fL https://github.com/bytecodealliance/javy/releases/download/v8.1.1/javy-x86_64-linux-v8.1.1.gz -o /tmp/javy.gz
echo '4bec224e1d51827808fd063541a2b4d94cf474744636b692be63e7a29bec83a6  /tmp/javy.gz' | sha256sum -c -
gzip -dc /tmp/javy.gz > /tmp/javy
chmod +x /tmp/javy
JAVY=/tmp/javy native/javex_plugin/build

# Verify the bundled binary independently of rebuilding:
echo 'dbe33a57dd668daaa8f09fa63392674b86d14ec229eceb838625f31aeca01672  priv/javy_plugin.wasm' | sha256sum -c -
```

Building the provider is a maintainer task, not an installation requirement.
The build uses the checked-in Cargo lockfile and deterministic initialization.
Provider changes require compatibility tests and recompilation of dynamic
modules; modules compiled with the previous default provider must be recompiled.
Other custom providers must be trusted, initialized Javy providers supporting
the same `cabi_realloc` / `compile-src` / `invoke` ABI; they do not automatically
gain the JS callback API. The namespace alone does not establish compatibility
or trust.

## Development and verification

```sh
mise install
mix deps.get
JAVEX_BUILD=1 mix test --cover
mix format --check-formatted
JAVEX_BUILD=1 mix credo --strict
cargo fmt --manifest-path native/javex_nif/Cargo.toml --check
cargo fmt --manifest-path native/javex_plugin/Cargo.toml --check
cargo clippy --manifest-path native/javex_nif/Cargo.toml --all-targets --locked -- -D warnings
cargo test --manifest-path native/javex_nif/Cargo.toml --release --locked
```

Elixir coverage excludes only the replaced NIF fallback bodies; Rust buffer
contracts are tested separately. CI audits dependencies, and release jobs gate
publication on CI and load/run each packaged NIF on its target platform.

## 📄 License

[MIT](https://github.com/tuist/javex/blob/main/LICENSE).
