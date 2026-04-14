# Javex

Compile JavaScript to WebAssembly with [Javy](https://github.com/bytecodealliance/javy)
and run it on [wasmtime](https://wasmtime.dev/), from Elixir.

Javex uses **dynamic linking by default**: each compiled module imports
QuickJS from a shared Javy plugin that is instantiated once per
`Javex.Runtime`. Compiled modules are tiny (a few KB) and cold starts
are fast enough to spin up a fresh instance per call.

```elixir
{:ok, mod} = Javex.compile(~S"""
  const input = JSON.parse(readInput());
  writeOutput(JSON.stringify({ sum: input.a + input.b }));
""")

{:ok, %{"sum" => 3}} = Javex.run(mod, %{a: 1, b: 2})
```

## Installation

```elixir
def deps do
  [{:javex, "~> 0.1"}]
end
```

Javex ships a Rust NIF (built with [Rustler](https://github.com/rusterlium/rustler))
that wraps `javy-codegen` and `wasmtime`. A Rust toolchain is required at
build time. The Javy plugin Wasm is bundled in `priv/`.

## API

- `Javex.compile/2` — compile a JS source string into a `Javex.Module`.
- `Javex.run/3` — run a compiled module with JSON or raw byte I/O.
- `Javex.Module.write/2` / `Javex.Module.read/1` — persist and reload.
- `Javex.Runtime.start_link/1` — start additional runtimes with custom
  fuel, memory, or timeout defaults.

## Design

See `lib/javex.ex` for the full module docs. A few highlights:

- One `Javex.Runtime` is started by default under `Javex.Application`.
  wasmtime's `Engine` is `Send + Sync`, so one runtime handles the whole
  BEAM. Spin up extra runtimes when you need different resource tiers.
- Each call creates a fresh Store and instance. This is viable precisely
  because dynamic linking keeps per-call cost low (the provider is
  already live).
- Modules track the SHA-256 of the provider plugin they were compiled
  against. Running on a runtime with a mismatched provider returns
  `{:error, %Javex.IncompatibleProviderError{}}` instead of a cryptic
  link-time trap.

## License

MIT.
