# Javex provider

This trusted Javy provider is built from `javy = 7.0.0` (the runtime used by
Javy CLI 8.1.1) and initialized with Javy CLI 8.1.1. Consumers use the checked-in
`priv/javy_plugin.wasm`; they do not need Javy, clang or a Wasm Rust target.

To rebuild, install the repo's mise toolchain, clang/libclang, and the Javy
8.1.1 CLI, then run `bash native/javex_plugin/build.sh`. Cargo.lock pins the
Rust dependencies. Provider changes require recompiling dynamic user modules.
The script normalizes embedded source paths and uses deterministic snapshot
initialization; CI rebuilds and compares the bundled bytes. Snapshot-seeded
`Math.random` is not cryptographically secure and can repeat across instances.
Use host-generated randomness for security-sensitive values.

## Resumable ABI v1

The provider implements Javy's `initialize-runtime`, `cabi_realloc`, `compile-src`,
and `invoke` exports, and namespace `javex-plugin-v1`. Compilation does not grant
or execute host callbacks. The initialized snapshot contains no credentials or
per-run state.

The execution driver configures and invokes a fresh instance once, then alternates
bounded Wasm steps with waiting for Elixir callback completions:

- `javex-configure-v1(calls: i32, concurrency: i32, input_bytes: i32) -> ()`
  installs the JS bridge and guest-side quotas before `_start`.
- `invoke(...)` evaluates the root module and retains its evaluation Promise.
- `javex-step-v1(ptr: i32, len: i32) -> record_ptr: i32` accepts a UTF-8 JSON
  array of completions. It delivers them in the same QuickJS context, executes
  runnable jobs until the root settles or no job is runnable, and reports state.
  No two steps may enter the same store concurrently.
- A record is three little-endian i32 fields: tag, payload pointer, payload length.
  Tag 0 is a JSON state; tag 1 is a JS diagnostic. The record/payload remain valid
  until the next provider call that produces output. Hosts bound lengths before
  copying and free their input allocation through `cabi_realloc(ptr,len,1,0)`.

State is `{done, fatal, requests: [{id, name, argument}]}`. `argument` is a JSON
string, not an arbitrary Elixir term. Completions are `{id, ok: true, value}`
(with JSON-string `value`) or `{id, ok: false, code, message}`. IDs correlate
out-of-order replies within this run only. A settled root drops undispatched
requests; the driver cancels dispatched work. An unresolved root with no host work
waits until its execution deadline. Terminal quotas cannot be caught away in JS.

Guest-side checks improve error reporting but are not a security boundary. BEAM
independently checks grants, unique IDs, call counts, active callbacks, and payload
sizes, including for forged Wasm/worker messages. The isolated supervisor bounds
frames, frame counts, and cumulative traffic to 64 MiB in each direction. It relays
only protocol data; child networking/filesystem/process restrictions stay intact.

Custom providers without these versioned exports still execute synchronously.
