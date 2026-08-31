defmodule ExDaytona.Api.AdminTest do
  use TestCase, async: true

  alias ExDaytona.Api.Admin
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "admin_get_all_audit_logs/2" do
    test "decodes the paginated audit logs", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/admin/audit", 200, %{
        items: [],
        page: 1,
        total: 0,
        totalPages: 0
      })

      assert {:ok, %Model.PaginatedAuditLogs{page: 1, items: []}} =
               Admin.admin_get_all_audit_logs(conn)
    end
  end

  describe "admin_get_message_attempts/4" do
    # Regression: {200, []} mappings (arrays of untyped objects) crashed the
    # deserializer before the request_builder template learned to plain-JSON
    # decode them.
    test "an array-of-objects response decodes to a plain list of maps", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_get(
        bypass,
        "/admin/webhooks/organizations/org-1/messages/msg-1/attempts",
        200,
        [%{status: "delivered", attempt: 1}]
      )

      assert {:ok, [%{"status" => "delivered", "attempt" => 1}]} =
               Admin.admin_get_message_attempts(conn, "org-1", "msg-1")
    end
  end

  describe "admin_list_users/2" do
    test "a 200 mapped as passthrough returns the raw env", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/admin/users", 200, [])

      assert {:ok, %Tesla.Env{status: 200}} = Admin.admin_list_users(conn)
    end
  end
end
