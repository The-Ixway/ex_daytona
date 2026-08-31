defmodule ExDaytona.Api.AuditTest do
  use TestCase, async: true

  alias ExDaytona.Api.Audit
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_organization_audit_logs/3" do
    test "sends pagination filters as query parameters and decodes the page", %{
      bypass: bypass,
      conn: conn
    } do
      Bypass.expect_once(bypass, "GET", "/audit/organizations/org-1", fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["page"] == "2"
        assert query["limit"] == "10"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{items: [], page: 2, total: 0, totalPages: 0}))
      end)

      assert {:ok, %Model.PaginatedAuditLogs{page: 2, items: []}} =
               Audit.get_organization_audit_logs(conn, "org-1", page: 2, limit: 10)
    end
  end

  describe "get_audit_scenarios/2" do
    test "decodes the scenarios", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/audit/scenarios", 200, %{})

      assert {:ok, %Model.AuditScenarios{}} = Audit.get_audit_scenarios(conn)
    end
  end
end
