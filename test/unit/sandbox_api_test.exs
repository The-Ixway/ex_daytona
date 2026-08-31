defmodule ExDaytona.Api.SandboxTest do
  use TestCase, async: true

  alias ExDaytona.Api.Sandbox
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "list_sandboxes/2" do
    test "decodes items into SandboxListItem structs", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/sandbox", 200, %{
        items: [
          %{id: "sb-1", state: "started"},
          %{id: "sb-2", state: "stopped"}
        ],
        nextCursor: "cursor-abc"
      })

      assert {:ok, %Model.ListSandboxesResponse{items: items, nextCursor: "cursor-abc"}} =
               Sandbox.list_sandboxes(conn)

      assert [%Model.SandboxListItem{id: "sb-1"}, %Model.SandboxListItem{id: "sb-2"}] = items
    end

    test "sends optional filters as query parameters", %{bypass: bypass, conn: conn} do
      Bypass.expect_once(bypass, "GET", "/sandbox", fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["limit"] == "5"
        assert query["name"] == "my-sandbox"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{items: []}))
      end)

      assert {:ok, %Model.ListSandboxesResponse{items: []}} =
               Sandbox.list_sandboxes(conn, limit: 5, name: "my-sandbox")
    end
  end

  describe "get_sandbox/3" do
    test "decodes a sandbox with its toolboxProxyUrl", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/sandbox/sb-1", 200, %{
        id: "sb-1",
        state: "started",
        toolboxProxyUrl: "https://proxy.app.daytona.io/toolbox"
      })

      assert {:ok, %Model.Sandbox{id: "sb-1", toolboxProxyUrl: proxy}} =
               Sandbox.get_sandbox(conn, "sb-1")

      assert proxy == "https://proxy.app.daytona.io/toolbox"
    end
  end

  describe "create_sandbox/3" do
    test "posts the request body and decodes the created sandbox", %{bypass: bypass, conn: conn} do
      Bypass.expect_once(bypass, "POST", "/sandbox", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"snapshot" => "my-snapshot"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "sb-new", state: "creating"}))
      end)

      assert {:ok, %Model.Sandbox{id: "sb-new"}} =
               Sandbox.create_sandbox(conn, %Model.CreateSandbox{snapshot: "my-snapshot"})
    end
  end

  describe "undeclared statuses" do
    test "a rate-limit response returns an error tuple with a decoded body", %{bypass: bypass} do
      # retry: false — 429 on a GET is normally retried by the Retry
      # middleware, which would re-hit the expect_once expectation.
      conn = Connection.new(base_url: MockServer.url(bypass), retry: false)

      MockServer.expect_get(bypass, "/sandbox/sb-1", 429, %{message: "rate limited"})

      assert {:error, %Tesla.Env{status: 429, body: %{"message" => "rate limited"}}} =
               Sandbox.get_sandbox(conn, "sb-1")
    end
  end
end
