defmodule ExDaytona.Api.FileSystemTest do
  use TestCase, async: true

  alias ExDaytona.Api.FileSystem
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "list_files/2" do
    test "sends the path as a query parameter and decodes FileInfo", %{
      bypass: bypass,
      conn: conn
    } do
      Bypass.expect_once(bypass, "GET", "/files", fn conn ->
        assert URI.decode_query(conn.query_string)["path"] == "/home/user"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!(%{name: "user", isDir: true, size: 0, mode: "drwxr-xr-x"})
        )
      end)

      assert {:ok, %Model.FileInfo{name: "user", isDir: true}} =
               FileSystem.list_files(conn, path: "/home/user")
    end

    test "a spec-declared 404 decodes into the error model (as :ok)", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_get(bypass, "/files", 404, %{message: "no such directory"})

      assert {:ok, %Model.ErrorResponse{message: "no such directory"}} =
               FileSystem.list_files(conn, path: "/nope")
    end
  end
end
