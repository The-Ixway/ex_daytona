defmodule ExDaytona.WebSocketTest do
  use TestCase, async: true

  alias ExDaytona.Error
  alias ExDaytona.WebSocket

  describe "connect/3 + send/receive" do
    test "upgrades, authenticates, and round-trips frames" do
      port = WsEchoServer.start()

      assert {:ok, ws} = WebSocket.connect("http://localhost:#{port}/any/path", "dtn_test")

      # The echo server reports the authorization header it saw
      assert_receive {:ex_daytona_ws, ^ws, {:text, "auth:Bearer dtn_test"}}, 5_000

      assert :ok = WebSocket.send_text(ws, "hello")
      assert_receive {:ex_daytona_ws, ^ws, {:text, "echo:hello"}}, 5_000

      assert :ok = WebSocket.send_binary(ws, <<1, 2, 3>>)
      assert_receive {:ex_daytona_ws, ^ws, {:binary, <<"echo:", 1, 2, 3>>}}, 5_000

      assert :ok = WebSocket.close(ws)
      assert_receive {:ex_daytona_ws, ^ws, {:closed, _reason}}, 5_000
    end

    test "delivers frames to an explicit owner" do
      port = WsEchoServer.start()
      parent = self()

      owner =
        spawn_link(fn ->
          receive do
            {:ex_daytona_ws, _ws, {:text, "auth:" <> _}} -> send(parent, :owner_got_frame)
          end
        end)

      assert {:ok, _ws} =
               WebSocket.connect("http://localhost:#{port}/", "dtn_test", owner: owner)

      assert_receive :owner_got_frame, 5_000
    end

    test "a non-websocket endpoint fails the upgrade with a normalized error" do
      bypass = MockServer.setup()

      MockServer.expect_once(bypass, "GET", "/no-ws", fn conn ->
        Plug.Conn.resp(conn, 404, "not here")
      end)

      assert {:error, %Error{}} =
               WebSocket.connect("http://localhost:#{bypass.port}/no-ws", "dtn_test")
    end

    test "an unreachable host fails cleanly" do
      assert {:error, %Error{}} = WebSocket.connect("http://localhost:1/nope", "dtn_test")
    end
  end
end
