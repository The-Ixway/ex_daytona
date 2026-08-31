defmodule ExDaytona.Api.VolumesTest do
  use TestCase, async: true

  alias ExDaytona.Api.Volumes
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "list_volumes/2" do
    test "decodes a list of VolumeDto structs", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/volumes", 200, [
        %{id: "vol-1", name: "data", state: "ready"}
      ])

      assert {:ok, [%Model.VolumeDto{id: "vol-1", name: "data", state: "ready"}]} =
               Volumes.list_volumes(conn)
    end
  end

  describe "get_volume_by_name/3" do
    test "targets the by-name path", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/volumes/by-name/data", 200, %{id: "vol-1", name: "data"})

      assert {:ok, %Model.VolumeDto{id: "vol-1"}} = Volumes.get_volume_by_name(conn, "data")
    end
  end

  describe "delete_volume/3" do
    test "a declared 409 conflict mapped as passthrough returns the raw env (as :ok)", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_delete(bypass, "/volumes/vol-1", 409, %{message: "volume in use"})

      # {409, false} in the mapping — a declared status with no model
      # passes the raw env through as :ok, NOT as an error tuple.
      assert {:ok, %Tesla.Env{status: 409}} = Volumes.delete_volume(conn, "vol-1")
    end
  end
end
