defmodule JavexTest do
  use ExUnit.Case, async: false

  @add_js ~S"""
  const input = JSON.parse(readInput());
  writeOutput(JSON.stringify({ sum: input.a + input.b }));
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
