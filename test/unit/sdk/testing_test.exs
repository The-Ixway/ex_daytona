defmodule ExDaytona.TestingTest do
  use TestCase, async: true

  # The public test-double surface SDK consumers build on. This is also
  # exercised indirectly by the snapshot/telemetry/FS-stream suites.

  alias ExDaytona.Error
  alias ExDaytona.LogStream
  alias ExDaytona.Model
  alias ExDaytona.Sandbox
  alias ExDaytona.Session
  alias ExDaytona.Testing

  describe "client/1 + expect/3" do
    test "answers facade calls from queued expectations, FIFO per route" do
      client = Testing.client()

      Testing.expect(:get, "/sandbox/sb-1", Testing.sandbox_json(%{id: "sb-1", state: "started"}))
      Testing.expect(:get, "/sandbox/sb-1", Testing.sandbox_json(%{id: "sb-1", state: "stopped"}))

      assert {:ok, first} = Sandbox.get(client, "sb-1")
      assert {:ok, second} = Sandbox.get(client, "sb-1")
      assert Sandbox.state(first) == "started"
      assert Sandbox.state(second) == "stopped"

      Testing.verify!()
    end

    test "fun responses see the request and drive the response" do
      client = Testing.client()

      Testing.expect(:post, "/sandbox", fn env ->
        assert %{"name" => "from-test"} = JSON.decode!(env.body)
        Testing.sandbox_json(%{id: "sb-fun"})
      end)

      assert {:ok, sandbox} = Sandbox.create(client, name: "from-test", wait: false)
      assert Sandbox.id(sandbox) == "sb-fun"
    end

    test "an unexpected request raises with the remaining expectations" do
      client = Testing.client()
      Testing.expect(:post, "/sandbox", Testing.sandbox_json())

      error =
        assert_raise Testing.UnexpectedRequestError, fn ->
          Sandbox.get(client, "sb-nope")
        end

      assert error.message =~ "GET /sandbox/sb-nope"
      assert error.message =~ "POST /sandbox"
    end

    test "verify!/0 raises on unconsumed expectations" do
      _client = Testing.client()
      Testing.expect(:delete, "/sandbox/leftover", 200)

      error = assert_raise Testing.VerificationError, fn -> Testing.verify!() end
      assert error.message =~ "DELETE /sandbox/leftover"
    end

    test "error-tuple responses surface as transport failures" do
      client = Testing.client()
      Testing.expect(:get, "/sandbox/sb-1", {:error, :econnrefused})

      assert {:error, %Error{outcome: :unknown}} = Sandbox.get(client, "sb-1")
    end

    test "bare statuses, keyword responses, and binary bodies work" do
      client = Testing.client()

      # Snapshot delete maps {200, false} — a bare status suffices
      Testing.expect(:delete, "/snapshots/snap-1", 200)

      Testing.expect(:get, "/sandbox/sb-2",
        status: 200,
        body: JSON.encode!(Testing.sandbox_json(%{id: "sb-2"})),
        headers: [{"content-type", "application/json"}, {"x-request-id", "req-42"}]
      )

      assert :ok = ExDaytona.Snapshot.delete(client, "snap-1")
      assert {:ok, sandbox} = Sandbox.get(client, "sb-2")
      assert Sandbox.id(sandbox) == "sb-2"
    end
  end

  describe "stub/3" do
    test "stubs are reusable and consulted after expectations" do
      client = Testing.client()

      Testing.stub(:get, "/sandbox/sb-1", Testing.sandbox_json(%{id: "sb-1", state: "stopped"}))
      Testing.expect(:get, "/sandbox/sb-1", Testing.sandbox_json(%{id: "sb-1", state: "started"}))

      # Expectation first, then the stub answers every later call
      assert {:ok, first} = Sandbox.get(client, "sb-1")
      assert {:ok, second} = Sandbox.get(client, "sb-1")
      assert {:ok, third} = Sandbox.get(client, "sb-1")
      assert Sandbox.state(first) == "started"
      assert Sandbox.state(second) == "stopped"
      assert Sandbox.state(third) == "stopped"

      Testing.verify!()
    end

    test "supports the create-then-poll flow" do
      client = Testing.client()

      Testing.expect(:post, "/sandbox", Testing.sandbox_json(%{id: "sb-poll", state: "creating"}))
      Testing.stub(:get, "/sandbox/sb-poll", Testing.sandbox_json(%{id: "sb-poll"}))

      assert {:ok, sandbox} = Sandbox.create(client, poll_interval: 5)
      assert Sandbox.state(sandbox) == "started"
    end
  end

  describe "sandbox/2" do
    test "builds a ready sandbox with overridable fields" do
      sandbox = Testing.sandbox(%{id: "sb-x", state: "stopped", toolbox_proxy_url: "http://tb"})

      assert %Model.Sandbox{id: "sb-x", state: "stopped", toolboxProxyUrl: "http://tb"} =
               sandbox.info

      assert %ExDaytona.Client{} = sandbox.client
    end

    test "unknown fields raise at build time" do
      assert_raise KeyError, fn -> Testing.sandbox(%{not_a_field: 1}) end
    end

    test "toolbox facades route through the suffix-matched expectations" do
      sandbox = Testing.sandbox()

      Testing.expect(:post, "/process/execute", %{exitCode: 7, result: "out"})

      assert {:ok, %{exit_code: 7, output: "out"}} = Sandbox.exec(sandbox, "false")
    end
  end

  describe "streaming doubles" do
    test "script_ws drives a LogStream opened through the client" do
      sandbox = Testing.sandbox()
      session = %Session{sandbox: sandbox, id: "s-1"}

      Testing.script_ws(frames: [{:binary, <<1, 1, 1>> <> "from-ws" <> <<2, 2, 2>> <> "warn"}])

      assert {:ok, stream} = Session.open_log_stream(session, "cmd-1", idle_timeout: :infinity)
      assert {:ok, collected} = LogStream.collect(stream)
      assert collected.stdout == "from-ws"
      assert collected.stderr == "warn"
    end

    test "script_ws connect errors surface from open" do
      sandbox = Testing.sandbox()
      session = %Session{sandbox: sandbox, id: "s-1"}

      Testing.script_ws(connect: {:error, %Error{message: "upgrade refused"}})

      assert {:error, %Error{message: message}} = Session.open_log_stream(session, "cmd-1")
      assert message =~ "upgrade refused"
    end

    test "script_http_stream drives HTTP follows and transfers" do
      sandbox = Testing.sandbox()

      Testing.script_http_stream(chunks: ["build ", "log"])

      parent = self()

      assert :ok =
               Session.stream_logs(
                 %Session{sandbox: sandbox, id: "s-1"},
                 "cmd-1",
                 fn chunk -> send(parent, {:chunk, chunk}) end
               )

      assert_received {:chunk, "build "}
      assert_received {:chunk, "log"}
    end

    test "the websocket double records sent frames and closes on demand" do
      Testing.script_ws(frames: [{:text, "hello"}], hold_open: true)

      {:ok, ws} = Testing.WebSocket.connect("ws://ignored", "dtn_test", owner: self())

      assert_receive {:ex_daytona_ws, ^ws, {:text, "hello"}}
      assert :ok = Testing.WebSocket.send_text(ws, "ping")
      assert :ok = Testing.WebSocket.send_binary(ws, <<1, 2>>)
      assert :ok = Testing.WebSocket.close(ws)
      assert_receive {:ex_daytona_ws, ^ws, {:closed, :normal}}
    end

    test "script_http_stream consumes upload bodies so sha/bytes work" do
      sandbox = Testing.sandbox()
      Testing.script_http_stream(status: 200)

      assert {:ok, %{bytes: 9, sha256: sha}} =
               ExDaytona.FS.upload_stream(sandbox, "/f.txt", ["chunk", "-two"])

      assert sha == :sha256 |> :crypto.hash("chunk-two") |> Base.encode16(case: :lower)
    end
  end

  describe "isolation" do
    test "expectations belong to the process that scripted them" do
      client = Testing.client()

      other =
        Task.async(fn ->
          # This process scripted nothing and owns no client: building its
          # own client and calling without expectations raises.
          own_client = Testing.client()

          assert_raise Testing.UnexpectedRequestError, fn ->
            Sandbox.get(own_client, "sb-elsewhere")
          end

          :done
        end)

      assert Task.await(other) == :done

      # ...while this process's client is answered by its own expectation.
      Testing.expect(:get, "/sandbox/sb-mine", Testing.sandbox_json(%{id: "sb-mine"}))
      assert {:ok, _} = Sandbox.get(client, "sb-mine")
    end
  end
end
