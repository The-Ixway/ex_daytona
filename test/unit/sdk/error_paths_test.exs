defmodule ExDaytona.ErrorPathsTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.FS
  alias ExDaytona.Model
  alias ExDaytona.PreviewProxy
  alias ExDaytona.Sandbox
  alias ExDaytona.Session

  defp build_sandbox(base_url, transports \\ []) do
    {:ok, client} =
      Client.new(api_key: "dtn_test", base_url: base_url, retry: false, transports: transports)

    %Sandbox{
      client: client,
      info: %Model.Sandbox{id: "sb-1", state: "started", toolboxProxyUrl: base_url <> "/toolbox"}
    }
  end

  describe "FS local write failures" do
    test "buffered download to an unwritable path errors cleanly" do
      bypass = MockServer.setup()
      sandbox = build_sandbox(MockServer.url(bypass))

      MockServer.expect_once(bypass, "GET", "/toolbox/sb-1/files/download", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.resp(200, "data")
      end)

      assert {:error, %Error{message: message}} =
               FS.download(sandbox, "/f", "/nonexistent-dir/#{System.unique_integer()}/out.bin")

      assert message =~ "cannot write"
    end

    test "streaming download_file to an unwritable directory errors before any request" do
      sandbox = build_sandbox("http://fake", http_stream: FakeTransports.HTTPStream)

      assert {:error, %Error{message: message}} =
               FS.download_file(sandbox, "/f", "/nonexistent-dir/#{System.unique_integer()}/o.bin")

      assert message =~ "cannot open"
    end
  end

  describe "Session.send_input/3 retry on the stdin-pipe race" do
    test "retries the input.pipe 500 and succeeds", %{} do
      bypass = MockServer.setup()
      sandbox = build_sandbox(MockServer.url(bypass))
      session = %Session{sandbox: sandbox, id: "s-1"}

      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      MockServer.expect(
        bypass,
        "POST",
        "/toolbox/sb-1/process/session/s-1/command/cmd-1/input",
        fn conn ->
          n = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

          if n < 3 do
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              500,
              JSON.encode!(%{
                message: "failed to open input pipe: open .../input.pipe: no such file",
                statusCode: 500
              })
            )
          else
            Plug.Conn.resp(conn, 204, "")
          end
        end
      )

      assert :ok = Session.send_input(session, "cmd-1", "yes\n")
      assert Agent.get(attempts, & &1) == 3
    end

    test "non-pipe errors do not retry" do
      bypass = MockServer.setup()
      sandbox = build_sandbox(MockServer.url(bypass))
      session = %Session{sandbox: sandbox, id: "s-1"}

      MockServer.expect_once(
        bypass,
        "POST",
        "/toolbox/sb-1/process/session/s-1/command/cmd-1/input",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(410, JSON.encode!(%{message: "command finished", statusCode: 410}))
        end
      )

      assert {:error, %Error{status: 410}} = Session.send_input(session, "cmd-1", "x")
    end
  end

  describe "PreviewProxy and ObjectStorage error paths" do
    test "signing_key and resolve_signed_token surface provider errors" do
      bypass = MockServer.setup()

      {:ok, client} =
        Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass), retry: false)

      MockServer.expect_get(bypass, "/preview/sb-1/signing-key", 500, %{message: "boom"})
      assert {:error, %Error{status: 500}} = PreviewProxy.signing_key(client, "sb-1")

      MockServer.expect_get(bypass, "/preview/tok/3000/sandbox-id", 403, %{message: "no"})
      assert {:error, %Error{status: 403}} = PreviewProxy.resolve_signed_token(client, "tok", 3000)
    end

    test "context upload PUT failure is normalized" do
      bypass = MockServer.setup()

      dir = Path.join(System.tmp_dir!(), "ex_daytona_os_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      file = Path.join(dir, "ctx.txt")
      File.write!(file, "content")

      access = %ExDaytona.ObjectStorage.Access{
        access_key: "AK",
        secret: "S",
        session_token: nil,
        bucket: "b",
        storage_url: "http://localhost:#{bypass.port}",
        region: "us-east-1",
        organization_id: "org-1"
      }

      MockServer.expect(bypass, fn conn ->
        case conn.method do
          "HEAD" -> Plug.Conn.resp(conn, 404, "")
          "PUT" -> Plug.Conn.resp(conn, 403, "denied")
        end
      end)

      assert {:error, %Error{status: 403}} =
               ExDaytona.ObjectStorage.upload_context_with_access(access, file)
    end
  end

  describe "WebSocket mid-stream disconnect" do
    test "a dropped connection notifies the owner and stops" do
      port = WsEchoServer.start()

      assert {:ok, ws} = ExDaytona.WebSocket.connect("http://localhost:#{port}/", "k")
      assert_receive {:ex_daytona_ws, ^ws, {:text, "auth:" <> _}}, 5_000

      ref = Process.monitor(ws)
      # Kill the server out from under the connection
      WsEchoServer.stop_all()

      assert_receive {:ex_daytona_ws, ^ws, {:closed, _reason}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^ws, _}, 5_000
    end
  end
end
