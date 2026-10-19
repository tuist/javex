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

    test "runtime backends and process limits cannot silently disable isolation" do
      Process.flag(:trap_exit, true)

      for opts <- [
            [backend: :unknown],
            [max_process_memory: nil],
            [max_process_memory: 0],
            [max_process_memory: 9_223_372_036_854_775_808],
            [max_process_memory: 18_446_744_073_709_551_615]
          ] do
        assert {:error, {:plugin_load_failed, %RuntimeError{kind: :invalid_options}}} =
                 Runtime.start_link(Keyword.put(opts, :name, unique_name("invalid_backend")))
      end
    end
  end

  describe "encoding" do
    test ":raw round-trips arbitrary bytes" do
      {:ok, mod} = Javex.compile(@raw_copy_js)

      for input <- [<<>>, <<0, 1, 2, 3, 4, 5, 255>>, String.duplicate("🌶é", 1500)] do
        assert {:ok, ^input} = Javex.run(mod, input, encoding: :raw)
      end
    end

    test ":raw rejects non-binary input" do
      {:ok, mod} = Javex.compile(@raw_copy_js)

      assert {:error, %RuntimeError{kind: :invalid_options}} =
               Javex.run(mod, %{not: "binary"}, encoding: :raw)
    end
  end

  describe "error translation" do
    test "an uncaught JS exception is returned as a RuntimeError" do
      {:ok, mod} = Javex.compile(@throw_js)

      assert {:error, %RuntimeError{kind: :js_error, message: msg} = error} = Javex.run(mod, nil)
      assert msg =~ "boom"
      assert msg =~ "function.mjs:1"
      assert Exception.message(error) =~ "boom"
    end

    test "an incompatible provider hash is rejected before execution" do
      {:ok, mod} = Javex.compile(@echo_js)
      tampered = %{mod | provider_hash: :crypto.hash(:sha256, "not the real plugin")}

      assert {:error, %IncompatibleProviderError{expected: expected, got: got} = error} =
               Javex.run(tampered, %{})

      assert byte_size(expected) == 32
      assert byte_size(got) == 32
      assert expected != got
      assert Exception.message(error) =~ "provider"
    end

    test "a runaway JS loop trips the epoch timeout" do
      {:ok, mod} = Javex.compile(@infinite_js)

      assert {:error, %RuntimeError{kind: :timeout}} =
               Javex.run(mod, nil, timeout: 200, fuel: 1_000_000_000_000)
    end

    test "fuel is finite even without a short wall-clock timeout" do
      {:ok, mod} = Javex.compile(@infinite_js)
      assert {:error, %RuntimeError{kind: :fuel_exhausted}} = Javex.run(mod, nil, fuel: 100_000)
    end

    test "max_memory is enforced at the store limiter" do
      {:ok, mod} = Javex.compile(@alloc_js)

      assert {:error, %RuntimeError{kind: :oom}} =
               Javex.run(mod, nil, max_memory: 8 * 1024 * 1024)
    end
  end

  describe "default_timeout vs GenServer.call deadline" do
    @tag timeout: 30_000
    test "a runtime with a default_timeout above 10s does not time out at the BEAM boundary" do
      name = unique_name("slow")

      {:ok, _pid} =
        Runtime.start_link(name: name, default_timeout: 10_500, default_fuel: 1_000_000_000_000)

      on_exit(fn -> stop_if_alive(name) end)

      {:ok, mod} = Javex.compile(@infinite_js)
      started = System.monotonic_time(:millisecond)

      assert {:error, %RuntimeError{kind: :timeout}} = Javex.run(mod, nil, runtime: name)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 10_000
      assert elapsed < 14_000
    end
  end

  describe "bounded sandbox" do
    test "runtime defaults apply and JSON failures remain errors rather than server exits" do
      name = start_runtime("defaults", default_max_input: 4, default_max_output: 4)
      {:ok, raw} = Javex.compile(@raw_copy_js)

      assert {:error, %RuntimeError{kind: :input_limit}} =
               Javex.run(raw, "abcde", runtime: name, encoding: :raw)

      assert {:ok, "abcde"} =
               Javex.run(raw, "abcde", runtime: name, encoding: :raw, max_input: 5, max_output: 5)

      {:ok, json} = Javex.compile(@echo_js)
      assert {:error, %Jason.EncodeError{}} = Javex.run(json, <<255>>, runtime: name)

      {:ok, invalid_json} =
        Javex.compile(~S|Javy.IO.writeSync(1, new TextEncoder().encode("no!"));|)

      assert {:error, %Jason.DecodeError{}} = Javex.run(invalid_json, nil, runtime: name)
      assert {:ok, 1} = Javex.run(json, 1, runtime: name)
    end

    test "input and stdout quotas include their exact byte boundary" do
      {:ok, mod} = Javex.compile(@raw_copy_js)
      assert {:ok, "abcde"} = Javex.run(mod, "abcde", encoding: :raw, max_input: 5, max_output: 5)

      assert {:error, %RuntimeError{kind: :input_limit}} =
               Javex.run(mod, "abcdef", encoding: :raw, max_input: 5)

      assert {:error, %RuntimeError{kind: :output_limit}} =
               Javex.run(mod, "abcdef", encoding: :raw, max_output: 5)

      {:ok, json} = Javex.compile(@echo_js)
      assert {:error, %RuntimeError{kind: :input_limit}} = Javex.run(json, "abc", max_input: 4)
    end

    test "streamed output cannot escape the guest memory cap through host buffers" do
      {:ok, mod} =
        Javex.compile("const buf = new Uint8Array(1024); while (true) Javy.IO.writeSync(1, buf);")

      assert {:error, %RuntimeError{kind: :output_limit}} =
               Javex.run(mod, nil, max_memory: 8 * 1024 * 1024, max_output: 4096)
    end

    test "stderr has an independent quota" do
      {:ok, mod} = Javex.compile(~S|Javy.IO.writeSync(2, new TextEncoder().encode("abcdef"));|)
      assert {:ok, nil} = Javex.run(mod, nil, max_stderr: 6)
      assert {:error, %RuntimeError{kind: :diagnostic_limit}} = Javex.run(mod, nil, max_stderr: 5)
    end

    test "malformed Wasm, metadata, and oversized modules are rejected without killing the runtime" do
      {:ok, mod} = Javex.compile(@echo_js)
      assert {:error, %RuntimeError{kind: :trap}} = Javex.run(%{mod | bytes: "not wasm"}, nil)

      assert {:error, %RuntimeError{kind: :invalid_options}} =
               Javex.run(%{mod | mode: :other}, nil)

      assert {:error, %RuntimeError{kind: :module_limit}} = Javex.run(mod, nil, max_module: 1)
      assert {:ok, %{"still" => "alive"}} = Javex.run(mod, %{still: "alive"})
    end

    test "invalid options never silently disable limits or stop the runtime" do
      {:ok, mod} = Javex.compile(@echo_js)

      for opts <- [
            [fuel: -1],
            [fuel: nil],
            [fuel: 18_446_744_073_709_551_616],
            [max_memory: 0],
            [max_output: -1],
            [timeout: 0],
            [timeout: 2_147_483_648],
            [encoding: :invalid],
            [callbacks: []],
            [callbacks: %{lookup: fn _, _ -> {:ok, nil} end}],
            [callbacks: %{"lookup" => fn _ -> {:ok, nil} end}],
            [callbacks: %{"" => fn _, _ -> {:ok, nil} end}],
            [callbacks: %{<<255>> => fn _, _ -> {:ok, nil} end}],
            [max_callback_calls: 1025],
            [max_callback_concurrency: 0],
            [max_callback_input: 0],
            [max_callback_output: 8 * 1024 * 1024 + 1],
            [callback_timeout: nil],
            [unknown: true],
            [fuel: 1, fuel: 2],
            [env: [{"A=B", "bad"}]],
            [env: [{"KEY", <<0>>}]],
            [env: [{"KEY", <<255>>}]],
            [env: List.duplicate({"A", "b"}, 129)],
            [env: [{"A", String.duplicate("b", 65_536)}]],
            %{fuel: 10}
          ] do
        assert {:error, %RuntimeError{kind: :invalid_options}} = Javex.run(mod, nil, opts)
      end

      assert {:ok, %{"valid" => true}} =
               Javex.run(mod, %{valid: true}, env: [{"EXPLICIT", "value"}])
    end

    test "each call gets fresh JS globals and the bundled environment has no host APIs" do
      {:ok, mod} =
        Javex.compile(~S"""
        globalThis.count = (globalThis.count || 0) + 1;
        const result = {count, fetch: typeof fetch, require: typeof require, process: typeof process};
        Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(result)));
        """)

      expected = %{
        "count" => 1,
        "fetch" => "undefined",
        "require" => "undefined",
        "process" => "undefined"
      }

      assert {:ok, ^expected} = Javex.run(mod, nil)
      assert {:ok, ^expected} = Javex.run(mod, nil)
    end

    test "WASI inherits no environment, filesystem preopens or socket descriptors" do
      bytes = File.read!(Path.expand("../fixtures/wasi_probe.wasm", __DIR__))
      mod = %Javex.Module{bytes: bytes, mode: :static}
      assert {:ok, [8, 8, 0]} = Javex.run(mod, nil)
      assert {:ok, [8, 8, 1]} = Javex.run(mod, nil, env: [{"EXPLICIT", "value"}])
      assert {:ok, [8, 8, 0]} = Javex.run(mod, nil)

      # Both memories fit separately, but the provider's 21 pages plus the
      # probe's 16 pages exceed 2 MiB. The limit applies to the whole store.
      dynamic = %{
        mod
        | mode: :dynamic,
          provider_hash: :crypto.hash(:sha256, Javex.Plugin.bytes!())
      }

      assert {:error, %RuntimeError{kind: :oom}} =
               Javex.run(dynamic, nil, max_memory: 2 * 1024 * 1024)

      assert {:ok, [8, 8, 0]} = Javex.run(dynamic, nil, max_memory: 3 * 1024 * 1024)
    end

    test "awaited Promise jobs finish before collecting stdout" do
      {:ok, mod} =
        Javex.compile(~S"""
        const value = await Promise.resolve(17).then(n => n + 6);
        Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(value)));
        """)

      assert {:ok, 23} = Javex.run(mod, nil)
    end

    test "an early failure cannot shorten the deadline of a later call" do
      name = start_runtime("deadlines")
      {:ok, mod} = Javex.compile(@infinite_js)
      missing_start = %{mod | bytes: <<0, 97, 115, 109, 1, 0, 0, 0>>}

      assert {:error, %RuntimeError{kind: :trap}} =
               Javex.run(missing_start, nil, runtime: name, timeout: 100)

      started = System.monotonic_time(:millisecond)

      assert {:error, %RuntimeError{kind: :timeout}} =
               Javex.run(mod, nil, runtime: name, timeout: 500, fuel: 1_000_000_000_000)

      assert System.monotonic_time(:millisecond) - started >= 450
    end
  end

  describe "admission and cancellation" do
    test "saturated runtimes stay responsive, reject excess work, and cancel when the caller dies" do
      name = start_runtime("capacity", max_concurrency: 1)
      {:ok, mod} = Javex.compile(@infinite_js)

      caller =
        spawn(fn ->
          Javex.run(mod, nil, runtime: name, timeout: 5000, fuel: 1_000_000_000_000)
        end)

      on_exit(fn -> Process.exit(caller, :kill) end)
      eventually(fn -> Runtime.stats(name).running == 1 end)

      assert Runtime.plugin_bytes(name) == Javex.Plugin.bytes!()
      assert {:error, %RuntimeError{kind: :busy}} = Javex.run(mod, nil, runtime: name)
      Process.exit(caller, :kill)
      eventually(fn -> Runtime.stats(name).running == 0 end)

      {:ok, echo} = Javex.compile(@echo_js)
      assert {:ok, 7} = Javex.run(echo, 7, runtime: name)
    end

    test "concurrent calls to one runtime return independent results" do
      name = start_runtime("concurrent")
      {:ok, mod} = Javex.compile(@echo_js)

      results =
        1..4
        |> Task.async_stream(fn n -> Javex.run(mod, %{n: n}, runtime: name) end,
          max_concurrency: 4,
          ordered: true
        )
        |> Enum.to_list()

      assert results == Enum.map(1..4, &{:ok, {:ok, %{"n" => &1}}})
    end

    test "unavailable runtimes return a structured error" do
      {:ok, mod} = Javex.compile(@echo_js)

      assert {:error, %RuntimeError{kind: :runtime_down}} =
               Javex.run(mod, nil, runtime: unique_name("absent"))
    end
  end

  describe "bounded compilation cache" do
    test "failed JS is cached and the least recently used module is evicted" do
      name = start_runtime("cache", max_cached_modules: 2)
      {:ok, first} = Javex.compile(@throw_js)
      {:ok, second} = Javex.compile(~S|Javy.IO.writeSync(1, new TextEncoder().encode("2"));|)
      {:ok, third} = Javex.compile(~S|Javy.IO.writeSync(1, new TextEncoder().encode("3"));|)
      assert {:error, %RuntimeError{kind: :js_error}} = Javex.run(first, nil, runtime: name)
      assert Runtime.stats(name).cached_modules == 1
      assert {:error, %RuntimeError{kind: :js_error}} = Javex.run(first, nil, runtime: name)
      assert Runtime.stats(name).cache_hits == 1
      assert {:ok, 2} = Javex.run(second, nil, runtime: name)
      assert {:error, %RuntimeError{kind: :js_error}} = Javex.run(first, nil, runtime: name)
      assert {:ok, 3} = Javex.run(third, nil, runtime: name)
      assert %{cached_modules: 2, cache_hits: 2} = Runtime.stats(name)
      assert {:ok, 2} = Javex.run(second, nil, runtime: name)
      assert Runtime.stats(name).cache_hits == 2
    end

    test "compiled-image byte limits can disable cache entries independently of count" do
      name = start_runtime("cache_bytes", max_cache_bytes: 1)
      {:ok, mod} = Javex.compile("// too big to cache")
      assert {:ok, nil} = Javex.run(mod, nil, runtime: name)
      assert %{cached_modules: 0, cache_bytes: 0} = Runtime.stats(name)
    end
  end

  for backend <- [:in_process] ++ if(:os.type() == {:unix, :linux}, do: [:isolated], else: []) do
    describe "#{backend} Promise callbacks" do
      @describetag timeout: 120_000

      setup do
        %{runtime: start_runtime("callbacks", backend: unquote(backend), max_concurrency: 1)}
      end

      test "Promise.all starts both callbacks before either finishes and correlates out-of-order replies",
           %{runtime: runtime} do
        parent = self()

        callback = fn value, %{deadline: deadline} ->
          send(parent, {:started, value, self(), deadline})

          receive do
            :finish -> {:ok, %{"value" => value}}
          end
        end

        for mode <- [:dynamic, :static] do
          {:ok, mod} =
            Javex.compile(
              ~S"""
              const values = await Promise.all([
                Javex.Host.call("lookup", "first"),
                Javex.Host.call("lookup", "second")
              ]);
              const again = await Javex.Host.call("lookup", "third");
              Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify([values, again])));
              """,
              mode: mode
            )

          task =
            Task.async(fn ->
              Javex.run(mod, nil,
                runtime: runtime,
                callbacks: %{"lookup" => callback},
                timeout: 30_000,
                callback_timeout: 10_000
              )
            end)

          assert_receive {:started, "first", first, deadline}, 10_000
          assert_receive {:started, "second", second, _}, 10_000
          assert deadline > System.monotonic_time(:millisecond)
          assert Runtime.stats(runtime).running == 1
          assert {:error, %RuntimeError{kind: :busy}} = Javex.run(mod, nil, runtime: runtime)
          ref = Process.monitor(second)
          send(second, :finish)
          assert_receive {:DOWN, ^ref, :process, ^second, :normal}
          send(first, :finish)
          assert_receive {:started, "third", third, _}, 10_000
          send(third, :finish)

          assert {:ok, [[%{"value" => "first"}, %{"value" => "second"}], %{"value" => "third"}]} =
                   Task.await(task, 30_000)
        end
      end

      test "grants are per-run and declared errors and crashes become safe JS rejections", %{
        runtime: runtime
      } do
        {:ok, mod} =
          Javex.compile(~S"""
          let result;
          try { result = await Javex.Host.call("lookup", {n: 7}); }
          catch (error) { result = {code: error.code, message: error.message, name: error.name}; }
          Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(result)));
          """)

        opts = [runtime: runtime, timeout: 30_000]

        assert {:ok, %{"n" => 7}} =
                 Javex.run(
                   mod,
                   nil,
                   opts ++ [callbacks: %{"lookup" => fn arg, _ -> {:ok, arg} end}]
                 )

        assert {:ok, %{"code" => "capability_denied", "name" => "HostError"}} =
                 Javex.run(mod, nil, opts)

        assert {:ok, %{"code" => "unavailable", "message" => "Try later"}} =
                 Javex.run(
                   mod,
                   nil,
                   opts ++
                     [
                       callbacks: %{
                         "lookup" => fn _, _ ->
                           {:error, %{"code" => "unavailable", "message" => "Try later"}}
                         end
                       }
                     ]
                 )

        assert {:ok, %{"code" => "callback_failed", "message" => "Host callback failed"}} =
                 Javex.run(
                   mod,
                   nil,
                   opts ++ [callbacks: %{"lookup" => fn _, _ -> raise "secret credential" end}]
                 )

        assert {:ok, %{"code" => "callback_failed"}} =
                 Javex.run(
                   mod,
                   nil,
                   opts ++ [callbacks: %{"lookup" => fn _, _ -> {:ok, %{not_json: self()}} end}]
                 )

        for callback <- [
              fn _, _ -> :invalid end,
              fn _, _ -> throw("secret credential") end,
              fn _, _ -> Process.exit(self(), :kill) end
            ] do
          assert {:ok, %{"code" => "callback_failed", "name" => "HostError"}} =
                   Javex.run(mod, nil, opts ++ [callbacks: %{"lookup" => callback}])
        end

        value = [nil, true, 1.25, %{"nested" => [false, 42]}]

        assert {:ok, ^value} =
                 Javex.run(
                   mod,
                   nil,
                   opts ++ [callbacks: %{"lookup" => fn _, _ -> {:ok, value} end}]
                 )

        assert {:error, %RuntimeError{kind: :callback_limit}} =
                 Javex.run(mod, nil, opts ++ [max_callback_output: 8])

        {:ok, uncaught} = Javex.compile(~S|await Javex.Host.call("missing", null);|)

        assert {:error, %RuntimeError{kind: :js_error, message: message}} =
                 Javex.run(uncaught, nil, opts)

        assert message =~ "Callback is not granted"
      end

      test "callback byte budgets include UTF-8 and exact boundaries and cannot be caught away",
           %{runtime: runtime} do
        {:ok, mod} =
          Javex.compile(~S"""
          try {
            const result = await Javex.Host.call("echo", "é");
            Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(result)));
          } catch (_) { Javy.IO.writeSync(1, new TextEncoder().encode('"caught"')); }
          """)

        opts = [
          runtime: runtime,
          timeout: 30_000,
          callbacks: %{"echo" => fn arg, _ -> {:ok, arg} end}
        ]

        assert {:ok, "é"} =
                 Javex.run(mod, nil, opts ++ [max_callback_input: 4, max_callback_output: 4])

        assert {:ok, ~s("é")} = Javex.run(mod, <<>>, opts ++ [encoding: :raw])

        for budget <- [[max_callback_input: 3], [max_callback_output: 3], [max_callback_calls: 0]] do
          assert {:error, %RuntimeError{kind: :callback_limit}} =
                   Javex.run(mod, nil, opts ++ budget)
        end

        {:ok, concurrent} =
          Javex.compile(~S"""
          try { await Promise.all([Javex.Host.call("echo", 1), Javex.Host.call("echo", 2)]); }
          catch (_) {}
          """)

        assert {:error, %RuntimeError{kind: :callback_limit}} =
                 Javex.run(concurrent, nil, opts ++ [max_callback_concurrency: 1])

        {:ok, sequential} =
          Javex.compile(~S"""
          try { await Javex.Host.call("echo", 1); await Javex.Host.call("echo", 2); }
          catch (_) {}
          """)

        assert {:error, %RuntimeError{kind: :callback_limit}} =
                 Javex.run(sequential, nil, opts ++ [max_callback_calls: 1])

        {:ok, reentrant} =
          Javex.compile(~S"""
          let nested;
          const first = Javex.Host.call("echo", {toJSON() {
            nested = Javex.Host.call("echo", 9);
            return 23;
          }});
          const result = await Promise.all([first, nested]);
          Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(result)));
          """)

        assert {:ok, [23, 9]} = Javex.run(reentrant, nil, opts)
      end

      test "caller death and callback timeout stop host work before releasing admission", %{
        runtime: runtime
      } do
        parent = self()

        callback = fn _, _ ->
          send(parent, {:waiting, self()})

          receive do
            :never -> {:ok, nil}
          end
        end

        {:ok, mod} = Javex.compile(~S|await Javex.Host.call("wait", null);|)

        caller =
          spawn(fn ->
            Javex.run(mod, nil,
              runtime: runtime,
              callbacks: %{"wait" => callback},
              callback_timeout: 30_000,
              timeout: 30_000
            )
          end)

        on_exit(fn -> Process.exit(caller, :kill) end)
        assert_receive {:waiting, worker}, 10_000
        ref = Process.monitor(worker)
        Process.exit(caller, :kill)
        assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 10_000
        eventually(fn -> Runtime.stats(runtime).running == 0 end)

        assert {:error, %RuntimeError{kind: :callback_timeout}} =
                 Javex.run(mod, nil,
                   runtime: runtime,
                   callbacks: %{"wait" => callback},
                   callback_timeout: 50,
                   timeout: 30_000
                 )

        assert_receive {:waiting, timed_out}, 10_000
        ref = Process.monitor(timed_out)
        assert_receive {:DOWN, ^ref, :process, ^timed_out, _}, 10_000
        assert Runtime.stats(runtime).running == 0
      end

      test "settling the root cancels detached callbacks before returning", %{runtime: runtime} do
        parent = self()

        callback = fn value, _ ->
          send(parent, {:race, value, self()})

          receive do
            :finish -> {:ok, value}
          end
        end

        {:ok, mod} =
          Javex.compile(~S"""
          const result = await Promise.race([Javex.Host.call("race", "winner"), Javex.Host.call("race", "detached")]);
          Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(result)));
          """)

        task =
          Task.async(fn ->
            Javex.run(mod, nil,
              runtime: runtime,
              callbacks: %{"race" => callback},
              timeout: 30_000,
              callback_timeout: 10_000
            )
          end)

        assert_receive {:race, "winner", winner}, 10_000
        assert_receive {:race, "detached", detached}, 10_000
        ref = Process.monitor(detached)
        send(winner, :finish)
        assert {:ok, "winner"} = Task.await(task, 30_000)
        assert_receive {:DOWN, ^ref, :process, ^detached, :killed}
        assert Runtime.stats(runtime).running == 0
      end

      test "overall deadlines and runtime shutdown also cancel pending callbacks", %{
        runtime: runtime
      } do
        parent = self()

        callback = fn _, _ ->
          send(parent, {:pending, self()})

          receive do
            :never -> {:ok, nil}
          end
        end

        {:ok, mod} = Javex.compile(~S|await Javex.Host.call("wait", null);|)
        opts = [runtime: runtime, callbacks: %{"wait" => callback}, callback_timeout: 30_000]
        task = Task.async(fn -> Javex.run(mod, nil, opts ++ [timeout: 15_000]) end)
        assert_receive {:pending, callback_pid}, 10_000
        ref = Process.monitor(callback_pid)
        assert {:error, %RuntimeError{kind: :timeout}} = Task.await(task, 20_000)
        assert_receive {:DOWN, ^ref, :process, ^callback_pid, :killed}, 10_000
        eventually(fn -> Runtime.stats(runtime).running == 0 end)

        task = Task.async(fn -> Javex.run(mod, nil, opts ++ [timeout: 30_000]) end)
        assert_receive {:pending, callback_pid}, 10_000
        ref = Process.monitor(callback_pid)
        GenServer.stop(runtime)
        assert {:error, %RuntimeError{kind: :runtime_down}} = Task.await(task, 10_000)
        assert_receive {:DOWN, ^ref, :process, ^callback_pid, :killed}, 10_000
      end

      test "an unresolved root waits for its deadline, even with no callback budget", %{
        runtime: runtime
      } do
        {:ok, mod} = Javex.compile("await new Promise(() => {});")

        assert {:error, %RuntimeError{kind: :timeout}} =
                 Javex.run(mod, nil, runtime: runtime, timeout: 1500, max_callback_calls: 0)
      end

      test "JS diagnostics respect their separate byte limit", %{runtime: runtime} do
        {:ok, mod} = Javex.compile(~S|throw new Error("secret".repeat(100));|)

        assert {:error, %RuntimeError{kind: :diagnostic_limit}} =
                 Javex.run(mod, nil, runtime: runtime, timeout: 30_000, max_stderr: 64)

        {:ok, mod} = Javex.compile(~S|throw new Error("x".repeat(9000));|)

        assert {:error, %RuntimeError{kind: :js_error, message: message}} =
                 Javex.run(mod, nil,
                   runtime: runtime,
                   timeout: 30_000,
                   max_callback_input: 1,
                   max_callback_concurrency: 1,
                   max_stderr: 16_384
                 )

        assert message =~ String.duplicate("x", 9000)
      end

      test "prototype mutation cannot corrupt the host bridge or suppress terminal limits", %{
        runtime: runtime
      } do
        {:ok, mod} =
          Javex.compile(~S"""
          Object.prototype.toJSON = function () {
            if ("fatal" in this) return {done: true, fatal: false, requests: []};
            return this;
          };
          Map.prototype.get = Map.prototype.set = Map.prototype.delete = () => { throw new Error("mutated Map"); };
          Object.defineProperty(Map.prototype, "size", {get() { throw new Error("mutated size"); }});
          Array.prototype.push = Array.prototype.join = () => { throw new Error("mutated Array"); };
          Array.prototype[Symbol.iterator] = () => { throw new Error("mutated iterator"); };
          const result = await Javex.Host.call('echo"🌶', {value: 'line\n"quoted"\\tail'});
          if (result.value !== 'line\n"quoted"\\tail') throw new Error("wrong callback result");
          Javy.IO.writeSync(1, new TextEncoder().encode("7"));
          """)

        assert {:ok, 7} =
                 Javex.run(mod, nil,
                   runtime: runtime,
                   timeout: 30_000,
                   callbacks: %{"echo\"🌶" => fn arg, _ -> {:ok, arg} end}
                 )

        {:ok, mod} =
          Javex.compile(~S"""
          Object.prototype.toJSON = function () {
            if ("fatal" in this) return {done: true, fatal: false, requests: []};
            return this;
          };
          try { await Javex.Host.call("echo", null); } catch (_) {}
          """)

        assert {:error, %RuntimeError{kind: :callback_limit}} =
                 Javex.run(mod, nil, runtime: runtime, timeout: 30_000, max_callback_calls: 0)
      end

      test "forged guest states cannot bypass host quotas or leave partial batches alive", %{
        runtime: runtime
      } do
        parent = self()
        bytes = File.read!(Path.expand("../fixtures/callback_probe.wasm", __DIR__))
        mod = %Javex.Module{bytes: bytes, mode: :static}

        callback = fn _, _ ->
          send(parent, {:forged, self()})

          receive do
            :never -> {:ok, nil}
          end
        end

        request = %{"id" => 1, "name" => "wait", "argument" => "null"}

        opts = [
          runtime: runtime,
          encoding: :raw,
          callbacks: %{"wait" => callback},
          timeout: 30_000
        ]

        state = Jason.encode!(%{done: false, requests: [request, request]})
        assert {:error, %RuntimeError{kind: :callback_limit}} = Javex.run(mod, state, opts)
        # The first callback may or may not have been scheduled before cleanup.
        receive do
          {:forged, pid} -> refute Process.alive?(pid)
        after
          0 -> :ok
        end

        for {requests, limits} <- [
              {[request], [max_callback_calls: 0]},
              {[request, %{request | "id" => 2}], [max_callback_concurrency: 1]},
              {[request], [max_callback_input: 3]}
            ] do
          state = Jason.encode!(%{done: false, requests: requests})

          assert {:error, %RuntimeError{kind: :callback_limit}} =
                   Javex.run(mod, state, opts ++ limits)

          refute_receive {:forged, _}, 10
        end

        assert Runtime.stats(runtime).running == 0
      end
    end
  end

  defp start_runtime(prefix, opts \\ []) do
    name = unique_name(prefix)
    {:ok, _} = Runtime.start_link(Keyword.put(opts, :name, name))
    on_exit(fn -> stop_if_alive(name) end)
    name
  end

  defp eventually(predicate, attempts \\ 200)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if !predicate.() do
      Process.sleep(10)
      eventually(predicate, attempts - 1)
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
  catch
    :exit, {:noproc, _} -> :ok
  end
end
