defmodule ExDaytona.Api.UsersTest do
  use TestCase, async: true

  alias ExDaytona.Api.Users
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_authenticated_user/2" do
    test "decodes the current User", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/users/me", 200, %{
        id: "u-1",
        email: "dev@example.com",
        emailVerified: true
      })

      assert {:ok, %Model.User{id: "u-1", email: "dev@example.com", emailVerified: true}} =
               Users.get_authenticated_user(conn)
    end
  end

  describe "get_available_account_providers/2" do
    test "decodes a list of AccountProvider structs", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/users/account-providers", 200, [
        %{name: "github", displayName: "GitHub"},
        %{name: "google", displayName: "Google"}
      ])

      assert {:ok, [%Model.AccountProvider{name: "github", displayName: "GitHub"}, _]} =
               Users.get_available_account_providers(conn)
    end
  end
end
