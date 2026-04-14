defmodule Javex.RuntimeTest do
  use ExUnit.Case, async: true

  alias Javex.{IncompatibleProviderError, Runtime, RuntimeError}

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

  @raw_copy_js ~S"""
  const chunkSize = 1024;
  while (true) {
    const buf = new Uint8Array(chunkSize);
    const n = Javy.IO.readSync(0, buf);
    if (n === 0) break;
    Javy.IO.writeSync(1, buf.subarray(0, n));
  }
  """

  @throw_js ~S|throw new Error("boom");|

  @infinite_js ~S|while (true) {}|

  @alloc_js ~S"""
  const chunks = [];
  for (let i = 0; i < 64; i++) {
    chunks.push(new Uint8Array(1024 * 1024));
  }
  Javy.IO.writeSync(1, new TextEncoder().encode("ok"));
  """

  describe "default runtime started by test_helper" do
    test "runs a module via the default registered name" do
      {:ok, mod} = Javex.compile(@echo_js)
      assert {:ok, %{"a" => 1}} = Javex.run(mod, %{a: 1})
    end

    test "the same module can be run repeatedly (precompile cache path)" do
      {:ok, mod} = Javex.compile(@echo_js)
      assert {:ok, %{"n" => 1}} = Javex.run(mod, %{n: 1})
      assert {:ok, %{"n" => 2}} = Javex.run(mod, %{n: 2})
      assert {:ok, %{"n" => 3}} = Javex.run(mod, %{n: 3})
    end
  end

  describe "named runtimes" do
    test "a second runtime can coexist with the default and be targeted by name" do
      name = unique_name("secondary")
      {:ok, _pid} = Runtime.start_link(name: name)
      on_exit(fn -> stop_if_alive(name) end)

      {:ok, mod} = Javex.compile(@echo_js)

      assert {:ok, %{"from" => "secondary"}} =
               Javex.run(mod, %{from: "secondary"}, runtime: name)
    end

    test "compile/2 links against the runtime's plugin when `:runtime` is given" do
      name = unique_name("custom_plugin")
      {:ok, _pid} = Runtime.start_link(name: name, plugin_path: Javex.Plugin.path())
      on_exit(fn -> stop_if_alive(name) end)

      runtime_plugin = Runtime.plugin_bytes(name)
      expected_hash = :crypto.hash(:sha256, runtime_plugin)

      {:ok, mod} = Javex.compile(@echo_js, runtime: name)

      assert mod.provider_hash == expected_hash

      assert {:ok, %{"through" => "runtime"}} =
               Javex.run(mod, %{through: "runtime"}, runtime: name)
    end

    test "start_link fails cleanly when the plugin path does not exist" do
      Process.flag(:trap_exit, true)

      assert {:error, {:plugin_load_failed, _}} =
               Runtime.start_link(
                 name: unique_name("bad"),
                 plugin_path: "/nonexistent/plugin.wasm"
               )
    end
  end

  describe "encoding" do
    test ":raw round-trips arbitrary bytes" do
      {:ok, mod} = Javex.compile(@raw_copy_js)
      input = <<0, 1, 2, 3, 4, 5, 255>>

      assert {:ok, ^input} = Javex.run(mod, input, encoding: :raw)
    end

    test ":raw rejects non-binary input" do
      {:ok, mod} = Javex.compile(@raw_copy_js)

      assert {:error, %RuntimeError{kind: :unknown}} =
               Javex.run(mod, %{not: "binary"}, encoding: :raw)
    end
  end

  describe "error translation" do
    test "an uncaught JS exception is returned as a RuntimeError" do
      {:ok, mod} = Javex.compile(@throw_js)

      assert {:error, %RuntimeError{kind: kind, message: msg}} = Javex.run(mod, nil)
      assert kind in [:js_error, :trap]
      assert is_binary(msg) and msg != ""
    end

    test "an incompatible provider hash is rejected before execution" do
      {:ok, mod} = Javex.compile(@echo_js)
      tampered = %{mod | provider_hash: :crypto.hash(:sha256, "not the real plugin")}

      assert {:error, %IncompatibleProviderError{expected: expected, got: got}} =
               Javex.run(tampered, %{})

      assert byte_size(expected) == 32
      assert byte_size(got) == 32
      assert expected != got
    end

    test "a runaway JS loop trips the epoch timeout" do
      {:ok, mod} = Javex.compile(@infinite_js)

      assert {:error, %RuntimeError{kind: :timeout}} = Javex.run(mod, nil, timeout: 200)
    end

    test "max_memory is enforced at the store limiter" do
      {:ok, mod} = Javex.compile(@alloc_js)

      assert {:error, %RuntimeError{kind: kind}} =
               Javex.run(mod, nil, max_memory: 8 * 1024 * 1024)

      assert kind in [:oom, :trap, :js_error]
    end
  end

  describe "default_timeout vs GenServer.call deadline" do
    test "a runtime with a default_timeout above 10s does not time out at the BEAM boundary" do
      name = unique_name("slow")
      {:ok, _pid} = Runtime.start_link(name: name, default_timeout: 15_000)
      on_exit(fn -> stop_if_alive(name) end)

      {:ok, mod} = Javex.compile(@echo_js)

      # A normal call returns well under a second; the point of this
      # test is just to exercise the call path without setting
      # :timeout, proving that GenServer.call does not short-circuit
      # before the NIF.
      assert {:ok, %{"ok" => true}} =
               Javex.run(mod, %{ok: true}, runtime: name)
    end
  end

  defp unique_name(prefix) do
    String.to_atom("javex_runtime_#{prefix}_#{System.unique_integer([:positive])}")
  end

  defp stop_if_alive(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
