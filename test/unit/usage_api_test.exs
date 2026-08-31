defmodule ExDaytona.Api.UsageTest do
  use TestCase, async: true

  alias ExDaytona.Api.Usage
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_organization_usage_aggregated/5" do
    test "sends from/to as query parameters and decodes the usage model", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_once(bypass, "GET", "/organization/org-1/usage/aggregated", fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["from"] == "2026-01-01T00:00:00Z"
        assert query["to"] == "2026-02-01T00:00:00Z"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!(%{sandboxCount: 3, totalCPUSeconds: 120.5, totalPrice: 1.23})
        )
      end)

      assert {:ok, %Model.ModelsAggregatedUsage{sandboxCount: 3}} =
               Usage.get_organization_usage_aggregated(
                 conn,
                 "org-1",
                 "2026-01-01T00:00:00Z",
                 "2026-02-01T00:00:00Z"
               )
    end
  end

  describe "get_organization_sandbox_usage/6" do
    test "targets the organization-scoped sandbox usage path", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/organization/org-1/sandbox/sb-1/usage", 200, %{})

      assert {:ok, _} =
               Usage.get_organization_sandbox_usage(
                 conn,
                 "org-1",
                 "sb-1",
                 "2026-01-01T00:00:00Z",
                 "2026-02-01T00:00:00Z"
               )
    end
  end
end
