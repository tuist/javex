defmodule Javex.IsolatedTest do
  use ExUnit.Case, async: true

  alias Javex.{CompileError, Runtime, RuntimeError}

  if :os.type() == {:unix, :linux} do
    @moduletag timeout: 120_000

    test "isolated compilation and execution preserve dynamic/static and raw/JSON contracts" do
      runtime = start_runtime()

      source = ~S"""
      const data = new Uint8Array(1024);
      const n = Javy.IO.readSync(0, data);
      Javy.IO.writeSync(1, data.subarray(0, n));
      """

      for mode <- [:dynamic, :static] do
        assert {:ok, mod} = Javex.compile(source, runtime: runtime, mode: mode, timeout: 30_000)

        assert {:ok, %{"n" => 17}} =
                 Javex.run(mod, %{n: 17}, runtime: runtime, timeout: 30_000)

        input = <<0, 255, 7, 128>>

        assert {:ok, ^input} =
                 Javex.run(mod, input, runtime: runtime, encoding: :raw, timeout: 30_000)
      end

      assert %{cached_modules: 0, cache_bytes: 0, running: 0} = Runtime.stats(runtime)
    end

    test "isolated diagnostics and quotas are returned without weakening the sandbox" do
      runtime = start_runtime()

      assert {:error, %CompileError{message: syntax}} =
               Javex.compile("const = ;", runtime: runtime, timeout: 30_000)

      assert syntax =~ "function.mjs:1"

      {:ok, throwing} = Javex.compile(~S|throw new Error("isolated boom");|)

      assert {:error, %RuntimeError{kind: :js_error, message: message}} =
               Javex.run(throwing, nil, runtime: runtime, timeout: 30_000)

      assert message =~ "isolated boom"

      {:ok, output} = Javex.compile(~S|Javy.IO.writeSync(1, new TextEncoder().encode("abcde"));|)

      assert {:ok, "abcde"} =
               Javex.run(output, <<>>,
                 runtime: runtime,
                 encoding: :raw,
                 max_output: 5,
                 timeout: 30_000
               )

      assert {:error, %RuntimeError{kind: :output_limit}} =
               Javex.run(output, <<>>,
                 runtime: runtime,
                 encoding: :raw,
                 max_output: 4,
                 timeout: 30_000
               )

      # Raising the guest input budget must not disable the independent IPC cap.
      large_input = :binary.copy(<<0>>, 64 * 1024 * 1024)

      assert {:error, %RuntimeError{kind: :input_limit, message: transport}} =
               Javex.run(output, large_input,
                 runtime: runtime,
                 encoding: :raw,
                 max_input: byte_size(large_input)
               )

      assert transport =~ "IPC"

      probe = %Javex.Module{
        bytes: File.read!(Path.expand("../fixtures/wasi_probe.wasm", __DIR__)),
        mode: :static
      }

      assert {:ok, [8, 8, 0]} = Javex.run(probe, nil, runtime: runtime, timeout: 30_000)

      assert {:ok, [8, 8, 1]} =
               Javex.run(probe, nil,
                 runtime: runtime,
                 env: [{"ONLY", "explicit"}],
                 timeout: 30_000
               )
    end

    test "OS allocation failure cannot crash BEAM or fall back to the NIF" do
      starved = start_runtime(max_process_memory: 1)
      assert {:error, %CompileError{message: message}} = Javex.compile("1", runtime: starved)
      assert message =~ "worker"
      {:ok, mod} = Javex.compile(~S|Javy.IO.writeSync(1, new TextEncoder().encode("23"));|)
      assert {:error, %RuntimeError{kind: :worker_error}} = Javex.run(mod, nil, runtime: starved)
      assert Process.alive?(starved)

      healthy = start_runtime()
      assert {:ok, 23} = Javex.run(mod, nil, runtime: healthy, timeout: 30_000)
    end

    test "deadlines and caller death release isolated admission for later calls" do
      runtime = start_runtime(max_concurrency: 1)
      {:ok, mod} = Javex.compile("while (true) {}")

      assert {:error, %RuntimeError{kind: :timeout}} =
               Javex.run(mod, nil, runtime: runtime, timeout: 100, fuel: 1_000_000_000_000)

      eventually(fn -> Runtime.stats(runtime).running == 0 end)

      caller =
        spawn(fn ->
          Javex.run(mod, nil, runtime: runtime, timeout: 30_000, fuel: 1_000_000_000_000)
        end)

      on_exit(fn -> Process.exit(caller, :kill) end)
      eventually(fn -> Runtime.stats(runtime).running == 1 end)
      assert {:error, %RuntimeError{kind: :busy}} = Javex.run(mod, nil, runtime: runtime)
      assert {:error, %CompileError{message: busy}} = Javex.compile("1", runtime: runtime)
      assert busy =~ "capacity"
      Process.exit(caller, :kill)
      eventually(fn -> Runtime.stats(runtime).running == 0 end)
      assert {:ok, _} = Javex.compile("1", runtime: runtime, timeout: 30_000)
    end

    defp start_runtime(opts \\ []) do
      name = String.to_atom("javex_isolated_#{System.unique_integer([:positive])}")
      {:ok, pid} = Runtime.start_link(Keyword.merge([name: name, backend: :isolated], opts))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      pid
    end

    defp eventually(predicate, attempts \\ 300)
    defp eventually(predicate, 0), do: assert(predicate.())

    defp eventually(predicate, attempts) do
      if !predicate.() do
        Process.sleep(10)
        eventually(predicate, attempts - 1)
      end
    end
  else
    test "unsupported platforms reject isolation rather than silently running in-process" do
      Process.flag(:trap_exit, true)
      name = String.to_atom("javex_unsupported_#{System.unique_integer([:positive])}")

      assert {:error, {:plugin_load_failed, message}} =
               Runtime.start_link(name: name, backend: :isolated)

      assert message =~ "requires Linux"
    end
  end
end
