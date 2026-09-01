defmodule ExDaytona.TransportTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.HTTPStream
  alias ExDaytona.Transport

  describe "Transport.resolve/1" do
    test "defaults, partial overrides, and client carry" do
      assert %{http_stream: ExDaytona.Transport.FinchStream, websocket: ExDaytona.WebSocket} =
               Transport.resolve(nil)

      assert %{http_stream: FakeTransports.HTTPStream, websocket: ExDaytona.WebSocket} =
               Transport.resolve(http_stream: FakeTransports.HTTPStream)

      {:ok, client} =
        Client.new(api_key: "dtn_test", transports: [websocket: FakeTransports.WS])

      assert Client.transport(client, :websocket) == FakeTransports.WS
      assert Client.transport(client, :http_stream) == ExDaytona.Transport.FinchStream
    end
  end

  describe "HTTPStream over an injected transport" do
    test "delivers chunks and completes" do
      FakeTransports.script_http(status: 200, chunks: ["one", "two"])
      {:ok, chunks} = Agent.start_link(fn -> [] end)

      assert :ok =
               HTTPStream.get(
                 "http://x/logs",
                 "k",
                 fn c -> Agent.update(chunks, &[c | &1]) end,
                 transport: FakeTransports.HTTPStream
               )

      assert Agent.get(chunks, &Enum.reverse/1) == ["one", "two"]
    end

    test "bounds non-2xx error bodies" do
      big = String.duplicate("x", 200_000)
      FakeTransports.script_http(status: 500, chunks: [big, big])

      assert {:error, %Error{status: 500, details: details}} =
               HTTPStream.get("http://x/logs", "k", fn _ -> :ok end, transport: FakeTransports.HTTPStream)

      # First chunk is accepted (crosses the bound), second is dropped
      assert byte_size(details) <= 200_000
    end

    test "enforces the overall deadline even while chunks keep arriving" do
      FakeTransports.script_http(
        status: 200,
        chunks: List.duplicate("tick", 50),
        chunk_delay: 10
      )

      assert {:error, %Error{message: message}} =
               HTTPStream.get("http://x/logs", "k", fn _ -> :ok end,
                 transport: FakeTransports.HTTPStream,
                 deadline: 50
               )

      assert message =~ "deadline"
    end

    test "surfaces transport failure" do
      FakeTransports.script_http(status: 200, chunks: ["a"], error: :econnrefused)

      assert {:error, %Error{message: message}} =
               HTTPStream.get("http://x/logs", "k", fn _ -> :ok end, transport: FakeTransports.HTTPStream)

      assert message =~ "econnrefused"
    end
  end

  describe "websocket consumers over an injected transport" do
    test "Pty.connect uses the client's ws transport" do
      {:ok, client} =
        Client.new(api_key: "dtn_test", transports: [websocket: FakeTransports.WS])

      sandbox = %ExDaytona.Sandbox{
        client: client,
        info: %ExDaytona.Model.Sandbox{id: "sb-1", toolboxProxyUrl: "http://fake"}
      }

      FakeTransports.script_ws(frames: [{:binary, "shell$ "}], hold_open: true)

      pty = %ExDaytona.Pty{sandbox: sandbox, id: "t1"}

      # A custom ws transport yields a handle; frames stay tagged with the pid
      assert {:ok, %ExDaytona.Transport.WSHandle{pid: pid} = ws} = ExDaytona.Pty.connect(pty)
      assert_receive {:ex_daytona_ws, ^pid, {:binary, "shell$ "}}

      assert :ok = ExDaytona.Pty.send_input(ws, "ls\n")
      assert :ok = ExDaytona.Pty.disconnect(ws)
      assert_receive {:ex_daytona_ws, ^pid, {:closed, :normal}}
    end

    test "CodeInterpreter.run over a scripted ws simulates disconnect mid-run" do
      {:ok, client} =
        Client.new(api_key: "dtn_test", transports: [websocket: FakeTransports.WS])

      sandbox = %ExDaytona.Sandbox{
        client: client,
        info: %ExDaytona.Model.Sandbox{id: "sb-1", toolboxProxyUrl: "http://fake"}
      }

      FakeTransports.script_ws(
        frames: [{:text, JSON.encode!(%{type: "stdout", text: "partial"})}],
        close_reason: {:error, :closed}
      )

      assert {:ok, %{stdout: "partial"}} = ExDaytona.CodeInterpreter.run(sandbox, "print(1)")
    end
  end
end
