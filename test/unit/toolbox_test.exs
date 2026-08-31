defmodule ExDaytona.ToolboxTest do
  use TestCase, async: true

  alias ExDaytona.Api.FileSystem
  alias ExDaytona.Api.Process
  alias ExDaytona.Model
  alias ExDaytona.Model.Sandbox
  alias ExDaytona.Toolbox

  describe "base_url/1" do
    test "joins toolboxProxyUrl and sandbox id" do
      sandbox = %Sandbox{id: "sb-123", toolboxProxyUrl: "https://proxy.app.daytona.io/toolbox"}

      assert Toolbox.base_url(sandbox) == "https://proxy.app.daytona.io/toolbox/sb-123"
    end

    test "tolerates a trailing slash on toolboxProxyUrl" do
      sandbox = %Sandbox{id: "sb-123", toolboxProxyUrl: "https://proxy.app.daytona.io/toolbox/"}

      assert Toolbox.base_url(sandbox) == "https://proxy.app.daytona.io/toolbox/sb-123"
    end

    test "raises a clear error when the sandbox has no toolboxProxyUrl" do
      assert_raise ArgumentError, ~r/sb-123.*toolboxProxyUrl/, fn ->
        Toolbox.base_url(%Sandbox{id: "sb-123", toolboxProxyUrl: nil})
      end
    end
  end

  describe "connection/2" do
    test "requests go to the sandbox's toolbox base URL", %{} do
      bypass = MockServer.setup()

      sandbox = %Sandbox{id: "sb-123", toolboxProxyUrl: MockServer.url(bypass)}

      MockServer.expect_post(bypass, "/sb-123/process/execute", 200, %{
        exitCode: 0,
        result: "hello\n"
      })

      conn = Toolbox.connection(sandbox)

      assert {:ok, %Model.ExecuteResponse{exitCode: 0, result: "hello\n"}} =
               Process.execute_command(conn, %Model.ExecuteRequest{command: "echo hello"})
    end

    test "forwards options like bearer_token to the connection" do
      bypass = MockServer.setup()
      sandbox = %Sandbox{id: "sb-1", toolboxProxyUrl: MockServer.url(bypass)}

      MockServer.expect_once(bypass, "GET", "/sb-1/files", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tb-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{name: "home", isDir: true}))
      end)

      conn = Toolbox.connection(sandbox, bearer_token: "tb-token")

      assert {:ok, %Model.FileInfo{}} = FileSystem.list_files(conn)
    end
  end
end
