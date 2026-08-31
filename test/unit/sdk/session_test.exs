defmodule ExDaytona.SessionTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Sandbox
  alias ExDaytona.Session

  setup do
    bypass = MockServer.setup()

    {:ok, client} =
      Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass), retry: false)

    sandbox = %Sandbox{
      client: client,
      info: %Model.Sandbox{
        id: "sb-1",
        state: "started",
        toolboxProxyUrl: MockServer.url(bypass) <> "/toolbox"
      }
    }

    {:ok, bypass: bypass, sandbox: sandbox}
  end

  describe "create/2" do
    test "posts the session id and returns the session", %{bypass: bypass, sandbox: sandbox} do
      MockServer.expect_once(bypass, "POST", "/toolbox/sb-1/process/session", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"sessionId" => "my-session"} = JSON.decode!(body)

        Plug.Conn.resp(conn, 201, "")
      end)

      assert {:ok, %Session{id: "my-session", sandbox: ^sandbox}} =
               Session.create(sandbox, id: "my-session")
    end

    test "generates an id when none is given", %{bypass: bypass, sandbox: sandbox} do
      MockServer.expect_once(bypass, "POST", "/toolbox/sb-1/process/session", fn conn ->
        Plug.Conn.resp(conn, 201, "")
      end)

      assert {:ok, %Session{id: "ex-daytona-" <> _}} = Session.create(sandbox)
    end
  end

  describe "run/2" do
    test "executes synchronously and normalizes the response", %{
      bypass: bypass,
      sandbox: sandbox
    } do
      session = %Session{sandbox: sandbox, id: "s-1"}

      MockServer.expect_once(bypass, "POST", "/toolbox/sb-1/process/session/s-1/exec", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"command" => "echo hi", "runAsync" => false} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{cmdId: "cmd-1", exitCode: 0, output: "hi\n"}))
      end)

      assert {:ok, %{cmd_id: "cmd-1", exit_code: 0, output: "hi\n"}} =
               Session.run(session, "echo hi")
    end
  end

  describe "run_async/2 + await/3 + logs/2" do
    test "starts a command and polls it to completion", %{bypass: bypass, sandbox: sandbox} do
      session = %Session{sandbox: sandbox, id: "s-1"}

      MockServer.expect_once(bypass, "POST", "/toolbox/sb-1/process/session/s-1/exec", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"runAsync" => true} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(202, JSON.encode!(%{cmdId: "cmd-9"}))
      end)

      assert {:ok, "cmd-9"} = Session.run_async(session, "sleep 99")

      # First poll: still running (exitCode null); second poll: finished.
      {:ok, polls} = Agent.start_link(fn -> 0 end)

      MockServer.expect(bypass, "GET", "/toolbox/sb-1/process/session/s-1/command/cmd-9", fn conn ->
        count = Agent.get_and_update(polls, &{&1 + 1, &1 + 1})
        exit_code = if count == 1, do: nil, else: 0

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!(%{id: "cmd-9", command: "sleep 99", exitCode: exit_code})
        )
      end)

      assert {:ok, %{exit_code: 0, command: "sleep 99"}} =
               Session.await(session, "cmd-9", poll_interval: 10)

      # Logs come back as plain text (the spec's JSON model is wrong here)
      MockServer.expect_once(
        bypass,
        "GET",
        "/toolbox/sb-1/process/session/s-1/command/cmd-9/logs",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.resp(200, "line-1\nline-2\n")
        end
      )

      assert {:ok, "line-1\nline-2\n"} = Session.logs(session, "cmd-9")
    end

    test "await/3 times out with a clear error", %{bypass: bypass, sandbox: sandbox} do
      session = %Session{sandbox: sandbox, id: "s-1"}

      MockServer.expect(bypass, "GET", "/toolbox/sb-1/process/session/s-1/command/cmd-9", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "cmd-9", exitCode: nil}))
      end)

      assert {:error, %Error{message: message}} =
               Session.await(session, "cmd-9", timeout: 30, poll_interval: 10)

      assert message =~ "timed out"
    end
  end

  describe "stream_logs/4" do
    test "delivers chunks incrementally as they arrive", %{bypass: bypass, sandbox: sandbox} do
      session = %Session{sandbox: sandbox, id: "s-1"}

      MockServer.expect_once(
        bypass,
        "GET",
        "/toolbox/sb-1/process/session/s-1/command/cmd-9/logs",
        fn conn ->
          assert URI.decode_query(conn.query_string)["follow"] == "true"
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer dtn_test"]

          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, "tick-1\n")
          {:ok, conn} = Plug.Conn.chunk(conn, "tick-2\n")
          conn
        end
      )

      {:ok, chunks} = Agent.start_link(fn -> [] end)

      assert :ok =
               Session.stream_logs(session, "cmd-9", fn chunk ->
                 Agent.update(chunks, &[chunk | &1])
               end)

      assert Agent.get(chunks, &Enum.reverse/1) == ["tick-1\n", "tick-2\n"]
    end

    test "a non-2xx response becomes a normalized error", %{bypass: bypass, sandbox: sandbox} do
      session = %Session{sandbox: sandbox, id: "s-1"}

      MockServer.expect_once(
        bypass,
        "GET",
        "/toolbox/sb-1/process/session/s-1/command/nope/logs",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(404, JSON.encode!(%{message: "command not found"}))
        end
      )

      assert {:error, %Error{status: 404, message: "command not found"}} =
               Session.stream_logs(session, "nope", fn _ -> :ok end)
    end
  end

  describe "send_input/3" do
    test "posts the data to the command's stdin", %{bypass: bypass, sandbox: sandbox} do
      session = %Session{sandbox: sandbox, id: "s-1"}

      MockServer.expect_once(
        bypass,
        "POST",
        "/toolbox/sb-1/process/session/s-1/command/cmd-9/input",
        fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert %{"data" => "y\n"} = JSON.decode!(body)

          Plug.Conn.resp(conn, 204, "")
        end
      )

      assert :ok = Session.send_input(session, "cmd-9", "y\n")
    end
  end

  describe "entrypoint" do
    test "entrypoint/1 decodes the entrypoint session", %{bypass: bypass, sandbox: sandbox} do
      MockServer.expect_get(bypass, "/toolbox/sb-1/process/session/entrypoint", 200, %{
        sessionId: "entrypoint",
        commands: [%{id: "c-1", command: "npm start", exitCode: nil}]
      })

      assert {:ok, %Model.Session{sessionId: "entrypoint", commands: [_]}} =
               Session.entrypoint(sandbox)
    end

    test "entrypoint_logs/1 returns the raw body", %{bypass: bypass, sandbox: sandbox} do
      MockServer.expect_once(
        bypass,
        "GET",
        "/toolbox/sb-1/process/session/entrypoint/logs",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.resp(200, "server listening\n")
        end
      )

      assert {:ok, "server listening\n"} = Session.entrypoint_logs(sandbox)
    end
  end

  describe "delete/1" do
    test "returns :ok", %{bypass: bypass, sandbox: sandbox} do
      session = %Session{sandbox: sandbox, id: "s-1"}

      MockServer.expect_once(bypass, "DELETE", "/toolbox/sb-1/process/session/s-1", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = Session.delete(session)
    end
  end

  describe "toolbox URL guard" do
    test "operations on a sandbox without a toolbox URL fail cleanly", %{sandbox: sandbox} do
      bare = %Sandbox{
        client: sandbox.client,
        info: %Model.Sandbox{id: "sb-x", toolboxProxyUrl: nil}
      }

      session = %Session{sandbox: bare, id: "s-1"}

      assert {:error, %Error{message: message}} = Session.run(session, "echo hi")
      assert message =~ "toolboxProxyUrl"

      assert {:error, %Error{message: stream_message}} =
               Session.stream_logs(session, "cmd-1", fn _ -> :ok end)

      assert stream_message =~ "toolboxProxyUrl"
    end
  end
end
