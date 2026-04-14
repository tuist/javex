# Javex – Agent guidance

This file is the root intent node for AI agents working in this repo. If
you are Claude Code, Codex, or any other agent, read this before you
edit tests or library code.

## What this repo is

Javex is an Elixir library that compiles JavaScript to Wasm with
[Javy](https://github.com/bytecodealliance/javy) and runs it on
wasmtime via a Rust NIF (`rustler_precompiled`). Dynamic linking is the
default — the provider plugin is bundled in `priv/javy_plugin.wasm` and
shared across instantiations — so compiled user modules stay tiny and
cold starts are cheap enough to spin up a fresh instance per call.

Starting a `Javex.Runtime` is the consumer's responsibility: they add
`Javex.Runtime` to their own supervision tree. Javex itself has no
application callback and nothing auto-starts.

## Testing conventions

Follow these when adding or editing any `*_test.exs`:

### Use `ExUnit.Case, async: true`

Aim to make every test case `async: true`. The runtime is a GenServer
that serializes its own state and the NIF creates a fresh wasmtime
`Store` per call, so concurrent `Javex.run/3` calls against the same
named runtime are safe.

If you need a dedicated runtime for a test, give it a unique name
derived from the test (for example via `:erlang.unique_integer/1`) so
parallel tests don't collide on a registered name, and stop it in an
`on_exit` callback.

### Use the `:tmp_dir` ExUnit tag, never `System.tmp_dir!` hacks

When a test needs a temporary directory or file, tag the test with
`@tag :tmp_dir` and destructure `%{tmp_dir: tmp_dir}` in the test
signature. ExUnit creates a dedicated, automatically-cleaned-up
directory for you.

**Do this:**

```elixir
@tag :tmp_dir
test "round-trips through disk", %{tmp_dir: tmp_dir} do
  path = Path.join(tmp_dir, "out.jxm")
  ...
end
```

**Do not do this:**

```elixir
setup do
  tmp = Path.join(System.tmp_dir!(), "javex_#{System.unique_integer([:positive])}.jxm")
  on_exit(fn -> File.rm(tmp) end)
  %{tmp: tmp}
end
```

The manual `System.tmp_dir!` pattern reinvents what ExUnit already
gives you, leaks across test runs when `on_exit` doesn't fire, and
forces `async: false`.

### Test helper must start a runtime

`test/test_helper.exs` is responsible for starting the default
`Javex.Runtime` that most tests target. Do not expect an automatic
start.

## Build and dev

- Elixir / Erlang / Rust versions are pinned in `mise.toml`. Run
  `mise install` before working in this repo.
- Force a local NIF build with `JAVEX_BUILD=1 mix compile` (otherwise
  `rustler_precompiled` tries to download an unreleased artifact).
- `mix test` runs the full suite. `mix format` before committing.

## Changelog and releases

This repo uses `git-cliff` with the config in `cliff.toml`. Commits
must follow Conventional Commits (`feat:`, `fix:`, `refactor:`, etc.)
so the changelog is generated correctly. Do not edit `CHANGELOG.md`
by hand — it is produced on release.

## Housekeeping

- `CLAUDE.md` is a symlink to this file. Keep editing `AGENTS.md`; the
  symlink is there so Claude Code's default discovery path still finds
  the guidance.
