defmodule ExDaytona.Api.SnapshotsTest do
  use TestCase, async: true

  alias ExDaytona.Api.Snapshots
  alias ExDaytona.Connection

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  # Add tests for each operation in ExDaytona.Api.Snapshots, for example:
  #
  #   test "lists things", %{bypass: bypass, conn: conn} do
  #     MockServer.expect_get(bypass, "/things", 200, %{things: []})
  #     assert {:ok, _response} = Snapshots.list_things(conn)
  #   end

  test "module is generated and loaded" do
    assert Code.ensure_loaded?(Snapshots)
  end
end
