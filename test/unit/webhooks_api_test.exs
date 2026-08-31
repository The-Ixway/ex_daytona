defmodule ExDaytona.Api.WebhooksTest do
  use TestCase, async: true

  alias ExDaytona.Api.Webhooks
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_initialization_status/3" do
    test "decodes the WebhookInitializationStatus", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(
        bypass,
        "/webhooks/organizations/org-1/initialization-status",
        200,
        %{organizationId: "org-1", svixApplicationId: "app_1", retryCount: 0}
      )

      assert {:ok, %Model.WebhookInitializationStatus{organizationId: "org-1", retryCount: 0}} =
               Webhooks.get_initialization_status(conn, "org-1")
    end

    test "a declared 404 mapped as passthrough returns the raw env (as :ok)", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_get(bypass, "/webhooks/organizations/org-1/initialization-status", 404)

      assert {:ok, %Tesla.Env{status: 404}} = Webhooks.get_initialization_status(conn, "org-1")
    end
  end

  describe "get_app_portal_access/3" do
    test "posts and decodes the portal access", %{bypass: bypass, conn: conn} do
      MockServer.expect_post(bypass, "/webhooks/organizations/org-1/app-portal-access", 200, %{
        url: "https://app.svix.com/portal",
        token: "tok"
      })

      assert {:ok, %Model.WebhookAppPortalAccess{}} =
               Webhooks.get_app_portal_access(conn, "org-1")
    end
  end
end
