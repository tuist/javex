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

      # Both memories fit separately, but the provider's 20 pages plus the
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

    test "pending Promise jobs fail instead of silently dropping workflow work" do
      {:ok, mod} = Javex.compile("Promise.resolve().then(() => {});")
      assert {:error, %RuntimeError{kind: :js_error, message: message}} = Javex.run(mod, nil)
      assert message =~ "Pending jobs"
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

  for backend <-
        if(:os.type() == {:unix, :linux}, do: [:in_process, :isolated], else: [:in_process]) do
    describe "#{backend} host callbacks" do
      @describetag timeout: 120_000
      @backend backend

      setup do
        %{runtime: start_runtime("callbacks", backend: @backend)}
      end

      test "dynamic and static modules chain JSON callbacks without changing stdin/stdout", %{
        runtime: runtime
      } do
        source = ~S"""
        const input = new Uint8Array(100);
        const n = Javy.IO.readSync(0, input);
        const value = JSON.parse(new TextDecoder().decode(input.subarray(0, n)));
        const first = Javex.Host.call("math", value);
        const second = Javex.Host.call("math", first);
        Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(second)));
        """

        callbacks = %{
          "math" => fn %{"n" => n}, %{deadline: deadline} ->
            assert deadline > System.monotonic_time(:millisecond)
            {:ok, %{"n" => n * 3 + 2}}
          end
        }

        for mode <- [:dynamic, :static] do
          assert {:ok, mod} = Javex.compile(source, mode: mode, runtime: runtime, timeout: 30_000)

          assert {:ok, %{"n" => 71}} =
                   Javex.run(mod, %{n: 7},
                     runtime: runtime,
                     callbacks: callbacks,
                     timeout: 30_000
                   )

          assert {:error, %RuntimeError{kind: :js_error, message: message}} =
                   Javex.run(mod, %{n: 7}, runtime: runtime, timeout: 30_000)

          assert message =~ "Callback not granted"
        end
      end

      test "errors are catchable, host crashes are sanitized, and grants do not persist", %{
        runtime: runtime
      } do
        {:ok, mod} =
          Javex.compile(~S"""
          let result;
          try { result = Javex.Host.call("service", null); }
          catch (error) { result = {name: error.name, code: error.code, message: error.message}; }
          Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(result)));
          """)

        nested = Enum.reduce(1..140, "leaf", fn _, value -> [value] end)

        cases = [
          {fn _, _ -> {:ok, [nil, true, "é", 17]} end, [nil, true, "é", 17]},
          {fn _, _ -> {:ok, nested} end, nested},
          {fn _, _ -> {:error, %{"code" => "offline", "message" => "Try later"}} end,
           %{"name" => "HostError", "code" => "offline", "message" => "Try later"}},
          {fn _, _ -> raise "private credentials" end,
           %{"name" => "HostError", "code" => "callback_failed", "message" => "Callback failed"}},
          {fn _, _ -> {:ok, %{not_json: self()}} end,
           %{
             "name" => "HostError",
             "code" => "callback_failed",
             "message" => "Callback result must be JSON-compatible"
           }}
        ]

        for {callback, expected} <- cases do
          assert {:ok, ^expected} =
                   Javex.run(mod, nil,
                     runtime: runtime,
                     callbacks: %{"service" => callback},
                     timeout: 30_000
                   )
        end

        assert {:ok, %{"code" => "callback_denied"}} =
                 Javex.run(mod, nil, runtime: runtime, timeout: 30_000)
      end

      test "call and encoded byte limits terminate execution rather than becoming catchable", %{
        runtime: runtime
      } do
        {:ok, mod} =
          Javex.compile(~S"""
          try {
            Javex.Host.call("echo", "abc");
            const result = Javex.Host.call("echo", "abc");
            Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(result)));
          } catch (_) { Javy.IO.writeSync(1, new TextEncoder().encode('"escaped"')); }
          """)

        callbacks = %{"echo" => fn arg, _ -> {:ok, arg} end}
        request_size = byte_size(~s({"name":"echo","argument":"abc"}))

        base = [
          runtime: runtime,
          callbacks: callbacks,
          timeout: 30_000,
          max_callback_calls: 2,
          max_callback_input: request_size,
          max_callback_output: 5
        ]

        assert {:ok, "abc"} = Javex.run(mod, nil, base)

        for override <- [
              [max_callback_calls: 1],
              [max_callback_calls: 0],
              [max_callback_input: request_size - 1],
              [max_callback_output: 4]
            ] do
          assert {:error, %RuntimeError{kind: :callback_limit}} =
                   Javex.run(mod, nil, Keyword.merge(base, override))
        end
      end

      test "callback deadlines stop callback processes and release admission", %{runtime: runtime} do
        {:ok, mod} = Javex.compile(~S|try { Javex.Host.call("wait", null); } catch (_) {}|)
        parent = self()

        callback = fn _, _ ->
          send(parent, {:callback, self()})
          Process.sleep(:infinity)
        end

        assert {:error, %RuntimeError{kind: :callback_timeout}} =
                 Javex.run(mod, nil,
                   runtime: runtime,
                   callbacks: %{"wait" => callback},
                   callback_timeout: 50,
                   timeout: 30_000
                 )

        assert_receive {:callback, pid}
        refute Process.alive?(pid)
        eventually(fn -> Runtime.stats(runtime).running == 0 end)

        assert {:error, %RuntimeError{kind: :timeout}} =
                 Javex.run(mod, nil,
                   runtime: runtime,
                   callbacks: %{"wait" => callback},
                   callback_timeout: 30_000,
                   timeout: 5000
                 )

        assert_receive {:callback, pid}
        eventually(fn -> not Process.alive?(pid) and Runtime.stats(runtime).running == 0 end)
      end

      test "caller death and runtime shutdown stop pending callbacks without blocking coordination",
           %{
             runtime: runtime
           } do
        {:ok, mod} = Javex.compile(~S|Javex.Host.call("wait", null);|)
        parent = self()

        callback = fn _, _ ->
          send(parent, {:callback, self()})
          Process.sleep(:infinity)
        end

        caller =
          spawn(fn ->
            Javex.run(mod, nil,
              runtime: runtime,
              callbacks: %{"wait" => callback},
              callback_timeout: 30_000,
              timeout: 60_000
            )
          end)

        on_exit(fn -> Process.exit(caller, :kill) end)
        assert_receive {:callback, pid}, 30_000
        monitor = Process.monitor(pid)
        assert Runtime.stats(runtime).running == 1

        assert {:error, %RuntimeError{kind: :js_error}} =
                 Javex.run(mod, nil, runtime: runtime, timeout: 30_000)

        Process.exit(caller, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5000
        eventually(fn -> Runtime.stats(runtime).running == 0 end)

        assert {:ok, nil} =
                 Javex.run(mod, nil,
                   runtime: runtime,
                   callbacks: %{"wait" => fn _, _ -> {:ok, nil} end},
                   timeout: 30_000
                 )

        waiting =
          Task.async(fn ->
            Javex.run(mod, nil,
              runtime: runtime,
              callbacks: %{"wait" => callback},
              callback_timeout: 30_000,
              timeout: 60_000
            )
          end)

        assert_receive {:callback, pid}, 30_000
        monitor = Process.monitor(pid)
        GenServer.stop(runtime)
        assert {:error, %RuntimeError{kind: :runtime_down}} = Task.await(waiting)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5000
      end

      test "HTTP executes in an Elixir callback with host-only credentials", %{runtime: runtime} do
        {:ok, _} = Application.ensure_all_started(:inets)
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        on_exit(fn -> :gen_tcp.close(listener) end)
        {:ok, port} = :inet.port(listener)

        server =
          Task.async(fn ->
            {:ok, socket} = :gen_tcp.accept(listener, 30_000)
            {:ok, request} = :gen_tcp.recv(socket, 0, 30_000)

            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 201 Created\r\nContent-Length: 7\r\nConnection: close\r\n\r\nhealthy"
              )

            :gen_tcp.close(socket)
            request
          end)

        callback = fn %{"path" => "/status"}, %{deadline: deadline} ->
          remaining = max(deadline - System.monotonic_time(:millisecond), 1)
          url = String.to_charlist("http://127.0.0.1:#{port}/status")

          {:ok, {{_, status, _}, _, body}} =
            :httpc.request(
              :get,
              {url, [{~c"authorization", ~c"Bearer host-only"}]},
              [timeout: remaining, connect_timeout: remaining],
              body_format: :binary
            )

          {:ok, %{"status" => status, "body" => body}}
        end

        {:ok, mod} =
          Javex.compile(~S"""
          const response = Javex.Host.call("http.request", {path: "/status"});
          Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify(response)));
          """)

        assert {:ok, %{"status" => 201, "body" => "healthy"}} =
                 Javex.run(mod, nil,
                   runtime: runtime,
                   callbacks: %{"http.request" => callback},
                   callback_timeout: 5000,
                   timeout: 30_000
                 )

        request = Task.await(server)
        assert request =~ "GET /status HTTP/1.1"
        assert String.downcase(request) =~ "authorization: bearer host-only"
      end
    end
  end

  test "callback options reject invalid grants and unbounded budgets" do
    {:ok, mod} = Javex.compile("")

    for opts <- [
          [callbacks: []],
          [callbacks: %{"x" => fn _ -> :ok end}],
          [callbacks: %{x: fn _, _ -> :ok end}],
          [callbacks: %{"" => fn _, _ -> :ok end}],
          [callback_timeout: nil],
          [max_callback_calls: -1],
          [max_callback_input: 0],
          [max_callback_output: 67_108_865]
        ] do
      assert {:error, %RuntimeError{kind: :invalid_options}} = Javex.run(mod, nil, opts)
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
