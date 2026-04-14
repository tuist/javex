defmodule JavexTest do
  use ExUnit.Case, async: false

  @add_js ~S"""
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

  const input = readInput();
  writeOutput({ sum: input.a + input.b });
  """

  test "compiles and runs a dynamic module" do
    {:ok, mod} = Javex.compile(@add_js)
    assert %Javex.Module{mode: :dynamic} = mod
    assert {:ok, %{"sum" => 3}} = Javex.run(mod, %{a: 1, b: 2})
  end

  test "round-trips through disk" do
    {:ok, mod} = Javex.compile(@add_js)
    path = Path.join(System.tmp_dir!(), "javex_test_#{System.unique_integer([:positive])}.jxm")
    :ok = Javex.Module.write(mod, path)
    {:ok, loaded} = Javex.Module.read(path)
    assert {:ok, %{"sum" => 5}} = Javex.run(loaded, %{a: 2, b: 3})
  after
    File.rm_rf!(Path.join(System.tmp_dir!(), "javex_test_*"))
  end

  test "surfaces JS errors" do
    {:ok, mod} = Javex.compile(~S|throw new Error("boom");|)
    assert {:error, %Javex.RuntimeError{kind: kind}} = Javex.run(mod, nil)
    assert kind in [:js_error, :trap]
  end
end
