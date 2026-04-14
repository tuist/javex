defmodule Javex.ModuleTest do
  use ExUnit.Case, async: true

  alias Javex.Module

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
  end
end
