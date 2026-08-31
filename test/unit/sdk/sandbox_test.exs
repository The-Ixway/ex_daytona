defmodule ExDaytona.SandboxTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Sandbox

  setup do
    bypass = MockServer.setup()

    {:ok, client} =
      Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass), retry: false)

    {:ok, bypass: bypass, client: client}
  end

  # Builds a facade sandbox whose toolbox URL also points at the mock server
  # (under /toolbox/<id>), the way the real toolboxProxyUrl works.
  defp mock_sandbox(bypass, client, id \\ "sb-1") do
    %Sandbox{
      client: client,
      info: %Model.Sandbox{
        id: id,
        state: "started",
        toolboxProxyUrl: MockServer.url(bypass) <> "/toolbox"
      }
    }
  end

  describe "create/2" do
    test "creates and returns immediately with wait: false", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/sandbox", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"snapshot" => "base", "ttlMinutes" => 30} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "sb-new", state: "creating"}))
      end)

      assert {:ok, %Sandbox{} = sandbox} =
               Sandbox.create(client, snapshot: "base", ttl_minutes: 30, wait: false)

      assert Sandbox.id(sandbox) == "sb-new"
      assert Sandbox.state(sandbox) == "creating"
    end

    test "waits for the started state by default", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/sandbox", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "sb-new", state: "creating"}))
      end)

      # First poll: still starting; second poll: started.
      {:ok, poll_count} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "GET", "/sandbox/sb-new", fn conn ->
        count = Agent.get_and_update(poll_count, &{&1 + 1, &1 + 1})
        state = if count == 1, do: "starting", else: "started"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "sb-new", state: state}))
      end)

      assert {:ok, %Sandbox{} = sandbox} =
               Sandbox.create(client, snapshot: "base", poll_interval: 10)

      assert Sandbox.state(sandbox) == "started"
    end

    test "rejects unknown options with a helpful error", %{client: client} do
      assert {:error, %Error{message: message}} = Sandbox.create(client, snapshotz: "typo")
      assert message =~ "unknown sandbox option :snapshotz"
      assert message =~ ":snapshot"
    end

    test "fails fast when the sandbox enters an error state", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/sandbox", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "sb-bad", state: "creating"}))
      end)

      Bypass.expect(bypass, "GET", "/sandbox/sb-bad", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!(%{id: "sb-bad", state: "error", errorReason: "no capacity"})
        )
      end)

      assert {:error, %Error{message: message}} =
               Sandbox.create(client, snapshot: "base", poll_interval: 10)

      assert message =~ ~s(entered state "error")
      assert message =~ "no capacity"
    end
  end

  describe "await_state/3" do
    test "times out with a clear error", %{bypass: bypass, client: client} do
      Bypass.expect(bypass, "GET", "/sandbox/sb-slow", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "sb-slow", state: "starting"}))
      end)

      {:ok, sandbox} = Sandbox.get(client, "sb-slow")

      assert {:error, %Error{message: message}} =
               Sandbox.await_state(sandbox, "started", timeout: 30, poll_interval: 10)

      assert message =~ "timed out"
      assert message =~ ~s("starting")
    end
  end

  describe "lifecycle" do
    test "start/2 with wait: false returns the API's new state", %{
      bypass: bypass,
      client: client
    } do
      MockServer.expect_get(bypass, "/sandbox/sb-1", 200, %{id: "sb-1", state: "stopped"})
      {:ok, sandbox} = Sandbox.get(client, "sb-1")

      MockServer.expect_post(bypass, "/sandbox/sb-1/start", 200, %{id: "sb-1", state: "starting"})

      assert {:ok, %Sandbox{} = started} = Sandbox.start(sandbox, wait: false)
      assert Sandbox.state(started) == "starting"
    end

    test "delete/2 accepts a bare id with a client", %{bypass: bypass, client: client} do
      MockServer.expect_delete(bypass, "/sandbox/sb-9", 200, %{id: "sb-9", state: "destroying"})

      assert :ok = Sandbox.delete("sb-9", client)
    end

    test "get/2 wraps the sandbox with its client", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/sandbox/sb-1", 200, %{id: "sb-1", state: "started"})

      assert {:ok, %Sandbox{client: ^client} = sandbox} = Sandbox.get(client, "sb-1")
      assert Sandbox.state(sandbox) == "started"
    end

    test "stop/2 with wait: false returns the API's new state", %{
      bypass: bypass,
      client: client
    } do
      MockServer.expect_get(bypass, "/sandbox/sb-1", 200, %{id: "sb-1", state: "started"})
      {:ok, sandbox} = Sandbox.get(client, "sb-1")

      MockServer.expect_post(bypass, "/sandbox/sb-1/stop", 200, %{id: "sb-1", state: "stopping"})

      assert {:ok, %Sandbox{} = stopped} = Sandbox.stop(sandbox, wait: false)
      assert Sandbox.state(stopped) == "stopping"
    end

    test "delete/1 returns :ok", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/sandbox/sb-1", 200, %{id: "sb-1", state: "started"})
      {:ok, sandbox} = Sandbox.get(client, "sb-1")

      MockServer.expect_delete(bypass, "/sandbox/sb-1", 200, %{id: "sb-1", state: "destroying"})

      assert :ok = Sandbox.delete(sandbox)
    end

    test "errors normalize to ExDaytona.Error", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/sandbox/nope", 404, %{
        message: "Sandbox not found",
        statusCode: 404
      })

      assert {:error, %Error{status: 404, message: "Sandbox not found"}} =
               Sandbox.get(client, "nope")
    end
  end

  describe "toolbox operations" do
    test "exec/3 posts to the sandbox's toolbox URL", %{bypass: bypass, client: client} do
      sandbox = mock_sandbox(bypass, client)

      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/process/execute", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer dtn_test"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"command" => "echo hi", "cwd" => "/workspace"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{exitCode: 0, result: "hi\n"}))
      end)

      assert {:ok, %{exit_code: 0, output: "hi\n"}} =
               Sandbox.exec(sandbox, "echo hi", cwd: "/workspace")
    end

    test "write_file/3 uploads multipart content", %{bypass: bypass, client: client} do
      sandbox = mock_sandbox(bypass, client)

      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/files/upload-v2", fn conn ->
        assert URI.decode_query(conn.query_string)["path"] == "/workspace/hello.txt"
        assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
        assert content_type =~ "multipart/form-data"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "hello world"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{name: "hello.txt"}))
      end)

      assert :ok = Sandbox.write_file(sandbox, "/workspace/hello.txt", "hello world")
    end

    test "read_file/2 returns the raw body", %{bypass: bypass, client: client} do
      sandbox = mock_sandbox(bypass, client)

      Bypass.expect_once(bypass, "GET", "/toolbox/sb-1/files/download", fn conn ->
        assert URI.decode_query(conn.query_string)["path"] == "/workspace/hello.txt"

        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.resp(200, "hello world")
      end)

      assert {:ok, "hello world"} = Sandbox.read_file(sandbox, "/workspace/hello.txt")
    end

    test "list_files/2 wraps single and list responses", %{bypass: bypass, client: client} do
      sandbox = mock_sandbox(bypass, client)

      MockServer.expect_get(bypass, "/toolbox/sb-1/files", 200, [
        %{name: "hello.txt", isDir: false}
      ])

      assert {:ok, [%Model.FileInfo{name: "hello.txt"}]} = Sandbox.list_files(sandbox)
    end

    test "toolbox operations on a sandbox without a toolbox URL fail cleanly", %{client: client} do
      sandbox = %Sandbox{client: client, info: %Model.Sandbox{id: "sb-x", toolboxProxyUrl: nil}}

      assert {:error, %Error{message: message}} = Sandbox.exec(sandbox, "echo hi")
      assert message =~ "toolboxProxyUrl"
    end
  end
end
