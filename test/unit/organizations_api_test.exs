defmodule ExDaytona.Api.OrganizationsTest do
  use TestCase, async: true

  alias ExDaytona.Api.Organizations
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_organization/3" do
    test "decodes an Organization", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/organizations/org-1", 200, %{
        id: "org-1",
        name: "Acme",
        defaultRegionId: "us"
      })

      assert {:ok, %Model.Organization{id: "org-1", name: "Acme"}} =
               Organizations.get_organization(conn, "org-1")
    end
  end

  describe "create_organization/3" do
    test "posts the body and decodes the 201 response", %{bypass: bypass, conn: conn} do
      MockServer.expect_once(bypass, "POST", "/organizations", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"name" => "Acme"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, JSON.encode!(%{id: "org-new", name: "Acme"}))
      end)

      assert {:ok, %Model.Organization{id: "org-new"}} =
               Organizations.create_organization(conn, %Model.CreateOrganization{name: "Acme"})
    end
  end

  describe "list_organization_members/3" do
    test "decodes a list of OrganizationUser structs", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/organizations/org-1/users", 200, [
        %{userId: "u-1", email: "a@example.com", role: "owner"},
        %{userId: "u-2", email: "b@example.com", role: "member"}
      ])

      assert {:ok, [%Model.OrganizationUser{userId: "u-1"}, %Model.OrganizationUser{}]} =
               Organizations.list_organization_members(conn, "org-1")
    end
  end

  describe "leave_organization/3" do
    test "a 204 mapped as passthrough returns the raw env", %{bypass: bypass, conn: conn} do
      # 204 responses must have an empty body per the HTTP spec
      MockServer.expect_once(bypass, "POST", "/organizations/org-1/leave", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert {:ok, %Tesla.Env{status: 204}} = Organizations.leave_organization(conn, "org-1")
    end
  end
end
