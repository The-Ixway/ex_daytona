defmodule ExDaytona.Api.SnapshotsTest do
  use TestCase, async: true

  alias ExDaytona.Api.Snapshots
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_all_snapshots/2" do
    test "decodes the paginated wrapper and its items", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/snapshots", 200, %{
        items: [%{id: "snap-1", name: "base", state: "active"}],
        page: 1,
        total: 1,
        totalPages: 1
      })

      assert {:ok, %Model.PaginatedSnapshots{items: [item], total: 1}} =
               Snapshots.get_all_snapshots(conn)

      assert %Model.SnapshotDto{id: "snap-1", name: "base"} = item
    end
  end

  describe "get_snapshot/3" do
    test "a declared 404 mapped as passthrough returns the raw env (as :ok)", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_get(bypass, "/snapshots/nope", 404, %{message: "not found"})

      assert {:ok, %Tesla.Env{status: 404}} = Snapshots.get_snapshot(conn, "nope")
    end
  end

  describe "create_snapshot/3" do
    test "posts the body and decodes the SnapshotDto", %{bypass: bypass, conn: conn} do
      Bypass.expect_once(bypass, "POST", "/snapshots", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"name" => "base"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "snap-new", name: "base"}))
      end)

      assert {:ok, %Model.SnapshotDto{id: "snap-new"}} =
               Snapshots.create_snapshot(conn, %Model.CreateSnapshot{name: "base"})
    end
  end
end
