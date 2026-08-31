defmodule ExDaytona.PtyTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Model
  alias ExDaytona.Pty
  alias ExDaytona.Sandbox

  defp build_sandbox(base_url) do
    {:ok, client} = Client.new(api_key: "dtn_test", base_url: base_url, retry: false)

    %Sandbox{
      client: client,
      info: %Model.Sandbox{
        id: "sb-1",
        state: "started",
        toolboxProxyUrl: base_url <> "/toolbox"
      }
    }
  end

  describe "create/2" do
    test "posts terminal settings and returns the pty" do
      bypass = MockServer.setup()
      sandbox = build_sandbox(MockServer.url(bypass))

      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/process/pty", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{"id" => "term-1", "cols" => 120, "rows" => 30, "cwd" => "/workspace"} =
                 JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, JSON.encode!(%{sessionId: "term-1"}))
      end)

      assert {:ok, %Pty{id: "term-1"}} =
               Pty.create(sandbox, id: "term-1", cols: 120, rows: 30, cwd: "/workspace")
    end
  end

  describe "connect/2 + send_input/2" do
    test "opens the pty websocket and round-trips input" do
      ws_port = WsEchoServer.start()
      sandbox = build_sandbox("http://localhost:#{ws_port}")
      pty = %Pty{sandbox: sandbox, id: "term-1"}

      assert {:ok, ws} = Pty.connect(pty)
      assert_receive {:ex_daytona_ws, ^ws, {:text, "auth:Bearer dtn_test"}}, 5_000

      assert :ok = Pty.send_input(ws, "ls\n")
      assert_receive {:ex_daytona_ws, ^ws, {:binary, "echo:ls\n"}}, 5_000

      assert :ok = Pty.disconnect(ws)
    end
  end

  describe "resize/3, info/1, list/1, delete/1" do
    test "manage the pty over the toolbox API" do
      bypass = MockServer.setup()
      sandbox = build_sandbox(MockServer.url(bypass))
      pty = %Pty{sandbox: sandbox, id: "term-1"}

      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/process/pty/term-1/resize", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"cols" => 200, "rows" => 50} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "term-1", cols: 200, rows: 50, active: true}))
      end)

      assert {:ok, %Model.PtySessionInfo{cols: 200, rows: 50}} = Pty.resize(pty, 200, 50)

      MockServer.expect_get(bypass, "/toolbox/sb-1/process/pty/term-1", 200, %{
        id: "term-1",
        active: true
      })

      assert {:ok, %Model.PtySessionInfo{id: "term-1", active: true}} = Pty.info(pty)

      MockServer.expect_get(bypass, "/toolbox/sb-1/process/pty", 200, %{
        sessions: [%{id: "term-1", active: true}]
      })

      assert {:ok, [%Model.PtySessionInfo{id: "term-1"}]} = Pty.list(sandbox)

      Bypass.expect_once(bypass, "DELETE", "/toolbox/sb-1/process/pty/term-1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{}))
      end)

      assert :ok = Pty.delete(pty)
    end
  end
end
