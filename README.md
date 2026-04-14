# Javex

Compile JavaScript to WebAssembly with [Javy](https://github.com/bytecodealliance/javy)
and run it on [wasmtime](https://wasmtime.dev/), from Elixir.

Javex uses **dynamic linking by default**: each compiled module imports
QuickJS from a shared Javy plugin that is instantiated once per
`Javex.Runtime`. Compiled modules are tiny (a few KB) and cold starts
are fast enough to spin up a fresh instance per call.

```elixir
js = ~S"""
function readInput() {
  const chunks = [];
  let total = 0;
  while (true) {
    const buf = new Uint8Array(1024);
    const n = Javy.IO.readSync(0, buf);
    if (n === 0) break;
    total += n;
    chunks.push(buf.subarray(0, n));
  }
  const out = new Uint8Array(total);
  let o = 0;
  for (const c of chunks) { out.set(c, o); o += c.length; }
  return JSON.parse(new TextDecoder().decode(out));
}

function writeOutput(value) {
  Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(value)));
}

const input = readInput();
writeOutput({ sum: input.a + input.b });
"""

{:ok, mod} = Javex.compile(js)
{:ok, %{"sum" => 3}} = Javex.run(mod, %{a: 1, b: 2})
```

Javy's default I/O surface is `Javy.IO.readSync(fd, buf)` and
`Javy.IO.writeSync(fd, buf)`; the `readInput` / `writeOutput` helpers
above are the convention from
[Javy's README](https://github.com/bytecodealliance/javy#example).

## Installation

```elixir
def deps do
  [{:javex, "~> 0.1"}]
end
```

Add a runtime to your application's supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  Javex.Runtime
  # or: {Javex.Runtime, default_fuel: 1_000_000}
]
```

`Javex.compile/2` works without any running process — it reads the
bundled provider plugin from `priv/` directly — so scripts and tests
can compile modules without starting a runtime.

Javex ships a Rust NIF (built with
[`rustler_precompiled`](https://github.com/philss/rustler_precompiled))
that wraps `javy-codegen` and `wasmtime`. Precompiled artifacts are
published as GitHub release assets, so consumers do not need a Rust
toolchain. Set `JAVEX_BUILD=1` to force a local source build. The Javy
plugin Wasm is bundled in `priv/`.

## API

- `Javex.compile/2` — compile a JS source string into a `Javex.Module`.
- `Javex.run/3` — run a compiled module with JSON or raw byte I/O.
- `Javex.Runtime.start_link/1` — start additional runtimes with custom
  fuel, memory, or timeout defaults.

`%Javex.Module{}` is a plain struct; if you need to persist one,
`:erlang.term_to_binary/1` round-trips it.

## Design

See `lib/javex.ex` for the full module docs. A few highlights:

- Starting a `Javex.Runtime` is the consumer's responsibility — add it
  to your own supervision tree. wasmtime's `Engine` is `Send + Sync`,
  so one runtime handles the whole BEAM. Spin up extra runtimes when
  you need different resource tiers (e.g. a tight fuel/memory cap for
  untrusted code).
- Each call creates a fresh Store and instance. This is viable
  precisely because dynamic linking keeps per-call cost low (the
  provider is already live).
- Modules track the SHA-256 of the provider plugin they were compiled
  against. Running on a runtime with a mismatched provider returns
  `{:error, %Javex.IncompatibleProviderError{}}` instead of a cryptic
  link-time trap.

## License

MIT.
