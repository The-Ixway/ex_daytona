defmodule ExDaytona.Api.RegionsTest do
  use TestCase, async: true

  alias ExDaytona.Api.Regions
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "list_shared_regions/2" do
    test "decodes a list of Region structs", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/shared-regions", 200, [
        %{id: "us", name: "United States", regionType: "shared"},
        %{id: "eu", name: "Europe", regionType: "shared"}
      ])

      assert {:ok, [%Model.Region{id: "us", name: "United States"}, %Model.Region{id: "eu"}]} =
               Regions.list_shared_regions(conn)
    end
  end
end
