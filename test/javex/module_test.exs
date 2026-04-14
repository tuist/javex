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

  describe "write/2 and read/1" do
    @tag :tmp_dir
    test "round-trips bytes, mode, and provider hash through disk", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "module.jxm")
      {:ok, original} = Javex.compile(@echo_js)

      :ok = Module.write(original, path)
      {:ok, loaded} = Module.read(path)

      assert loaded == original
    end

    @tag :tmp_dir
    test "a module loaded from disk executes end-to-end", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "module.jxm")
      {:ok, original} = Javex.compile(@echo_js)
      :ok = Module.write(original, path)
      {:ok, loaded} = Module.read(path)

      input = %{"hello" => "world", "n" => 42}
      assert {:ok, ^input} = Javex.run(loaded, input)
    end

    @tag :tmp_dir
    test "read/1 rejects files that are not a Javex envelope", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "garbage.jxm")
      File.write!(path, "not a javex module")

      assert {:error, :invalid_module_file} = Module.read(path)
    end

    @tag :tmp_dir
    test "read/1 surfaces filesystem errors", %{tmp_dir: tmp_dir} do
      assert {:error, :enoent} = Module.read(Path.join(tmp_dir, "missing.jxm"))
    end
  end

  describe "raw_wasm/1" do
    test "returns the compiled Wasm bytes unchanged" do
      {:ok, mod} = Javex.compile(@echo_js)
      assert Module.raw_wasm(mod) == mod.bytes
    end
  end
end
