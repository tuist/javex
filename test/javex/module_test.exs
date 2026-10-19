defmodule Javex.ModuleTest do
  use ExUnit.Case, async: true

  alias Javex.{CompileError, Module}

  @echo_js ~S"""
  function readInput() {
    const chunkSize = 1024;
    const chunks = [];
    let total = 0;
    while (true) {
      const buf = new Uint8Array(chunkSize);
      const n = Javy.IO.readSync(0, buf);
      if (n === 0) break;
      total += n;
      chunks.push(buf.subarray(0, n));
    }
    const out = new Uint8Array(total);
    let offset = 0;
    for (const c of chunks) { out.set(c, offset); offset += c.length; }
    return JSON.parse(new TextDecoder().decode(out));
  }

  function writeOutput(value) {
    const encoded = new TextEncoder().encode(JSON.stringify(value));
    Javy.IO.writeSync(1, encoded);
  }

  writeOutput(readInput());
  """

  describe "compile/1" do
    test "produces a dynamic module with non-empty bytes" do
      {:ok, mod} = Javex.compile(@echo_js)

      assert %Module{mode: :dynamic} = mod
      assert is_binary(mod.bytes)
      assert byte_size(mod.bytes) > 0
    end

    test "embeds the SHA-256 of the bundled provider plugin" do
      {:ok, mod} = Javex.compile(@echo_js)
      expected = :crypto.hash(:sha256, Javex.Plugin.bytes!())

      assert mod.provider_hash == expected
      assert byte_size(mod.provider_hash) == 32
    end

    test "static modules embed their provider and round-trip through serialization" do
      {:ok, mod} = Javex.compile(@echo_js, mode: :static)
      assert %Module{mode: :static, provider_hash: nil} = mod
      restored = mod |> :erlang.term_to_binary() |> :erlang.binary_to_term([:safe])
      assert {:ok, %{"static" => 17}} = Javex.run(restored, %{static: 17})
    end

    test "syntax errors preserve diagnostics and source locations" do
      assert {:error, %CompileError{message: message} = error} = Javex.compile("const = ;")
      assert message =~ "variable name expected"
      assert message =~ "function.mjs:1"
      assert Exception.message(error) =~ "variable name expected"
    end

    test "compilation times out without poisoning later compilations" do
      source = "const values = [" <> String.duplicate("1,", 50_000) <> "];"
      assert {:error, %CompileError{message: message}} = Javex.compile(source, timeout: 1)
      assert message =~ "timed out"
      assert {:ok, _} = Javex.compile("1")
    end

    test "source, compiler fuel, memory and result quotas are enforced" do
      assert {:ok, _} = Javex.compile("// abc", max_source: 6)

      assert {:error, %CompileError{message: "source limit exceeded"}} =
               Javex.compile("// abcd", max_source: 6)

      assert {:error, %CompileError{message: "fuel exhausted"}} = Javex.compile("1", fuel: 0)
      assert {:error, %CompileError{message: memory}} = Javex.compile("1", max_memory: 1)
      assert memory =~ "memory"
      assert {:error, %CompileError{}} = Javex.compile("1", max_module: 1)
      assert {:error, %CompileError{}} = Javex.compile("const = ;", max_stderr: 1)
    end

    test "malformed options, source encoding, providers, and missing runtimes return errors" do
      for opts <- [
            [mode: :unknown],
            [fuel: -1],
            [timeout: nil],
            [max_source: 0],
            [unknown: true],
            [mode: :static, mode: :dynamic],
            %{mode: :dynamic},
            [plugin: "not wasm"],
            [runtime: :javex_nonexistent_runtime]
          ] do
        assert {:error, %CompileError{}} = Javex.compile("1", opts)
      end

      assert {:error, %CompileError{}} = Javex.compile(<<255>>)
      assert {:ok, mod} = Javex.compile(@echo_js, plugin: Javex.Plugin.bytes!())
      assert {:ok, "🌶"} = Javex.run(mod, "🌶")
    end
  end
end
