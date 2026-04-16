# 🌶 Javex

> Run JavaScript inside your Elixir app, sandboxed in WebAssembly.

[![Hex.pm](https://img.shields.io/hexpm/v/javex.svg)](https://hex.pm/packages/javex)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/tuist/javex/actions/workflows/ci.yml/badge.svg)](https://github.com/tuist/javex/actions/workflows/ci.yml)

Javex compiles JavaScript to WebAssembly with [Javy](https://github.com/bytecodealliance/javy) and runs it on [wasmtime](https://wasmtime.dev/), so you can hand a snippet of user-written JS to a Wasm sandbox and get a typed result back. Each call gets a fresh instance — no shared state, nothing leaks between requests.

## ✨ Why you might want this

- 🧮 **User-defined transforms.** Let your users write small JS expressions to filter, map, or reshape data without giving them shell or BEAM access.
- 🔌 **Webhook / payload mappers.** Accept a JS snippet from a customer and run it on incoming events.
- 🧪 **Custom rules and DSLs** that need real expression power without inventing a parser.
- 🪶 **Tiny, fast.** Compiled modules are typically **a few KB**. Cold start is sub-millisecond once a runtime is up.
- 🔒 **Sandboxed by default.** Per-call fuel, memory, and wall-clock timeouts are first-class options.

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
| Run multiple tiers (trusted / untrusted) | `Javex.Runtime.start_link(name: :strict, default_fuel: …, default_max_memory: …)` |

Persisting compiled modules? `%Javex.Module{}` is a plain struct — `:erlang.term_to_binary/1` round-trips it, no helper needed.

## 🛡 Safety knobs

```elixir
{:ok, output} =
  Javex.run(mod, input,
    timeout: 250,                 # wall-clock ms
    fuel: 5_000_000,              # wasmtime fuel units
    max_memory: 8 * 1024 * 1024   # bytes
  )
```

Errors come back as a tagged tuple, never a process exit:

```elixir
{:error, %Javex.RuntimeError{kind: :timeout}}        # epoch deadline elapsed
{:error, %Javex.RuntimeError{kind: :fuel_exhausted}}
{:error, %Javex.RuntimeError{kind: :oom}}
{:error, %Javex.RuntimeError{kind: :js_error}}       # uncaught JS exception
```

## 🧠 How it works (in 60 seconds)

- Javy compiles your JS to a **dynamically-linked** Wasm module that imports QuickJS from a shared provider plugin (bundled in `priv/`). Each compiled module is a few KB instead of ~1 MB.
- `Javex.Runtime` owns one wasmtime `Engine` plus the preloaded plugin. The `Engine` is `Send + Sync`, so one runtime handles your whole BEAM. Spin up sibling runtimes when you need different resource tiers.
- Every `run/3` creates a fresh wasmtime `Store` and instance — clean JS state per call, with no measurable cold-start cost because the provider is already alive.
- The Rust NIF ships **precompiled** for macOS (Apple Silicon + Intel) and Linux (aarch64 + x86_64 GNU). No Rust toolchain required to install.

## 📄 License

[MIT](LICENSE).
