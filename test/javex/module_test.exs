defmodule Javex.ModuleTest do
  use ExUnit.Case, async: false

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

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "javex_mod_#{System.unique_integer([:positive])}.jxm"
      )

    on_exit(fn -> File.rm(tmp) end)
    %{tmp: tmp}
  end

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

  describe "write/2 and read/1" do
    test "round-trips bytes, mode, and provider hash through disk", %{tmp: tmp} do
      {:ok, original} = Javex.compile(@echo_js)

      :ok = Module.write(original, tmp)
      {:ok, loaded} = Module.read(tmp)

      assert loaded == original
    end

    test "a module loaded from disk executes end-to-end", %{tmp: tmp} do
      {:ok, original} = Javex.compile(@echo_js)
      :ok = Module.write(original, tmp)
      {:ok, loaded} = Module.read(tmp)

      input = %{"hello" => "world", "n" => 42}
      assert {:ok, ^input} = Javex.run(loaded, input)
    end

    test "read/1 rejects files that are not a Javex envelope", %{tmp: tmp} do
      File.write!(tmp, "not a javex module")
      assert {:error, :invalid_module_file} = Module.read(tmp)
    end

    test "read/1 surfaces filesystem errors", %{tmp: tmp} do
      assert {:error, :enoent} = Module.read(tmp)
    end
  end

  describe "raw_wasm/1" do
    test "returns the compiled Wasm bytes unchanged" do
      {:ok, mod} = Javex.compile(@echo_js)
      assert Module.raw_wasm(mod) == mod.bytes
    end
  end
end
