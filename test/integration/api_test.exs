defmodule ApiIntegrationTest do
  @moduledoc """
  Integration tests for the HTTP test harness.

  These tests use Bypass (via `MockServer`) and a Tesla + Finch client stack
  that mirrors what the generated SDK uses, proving the full
  request/response cycle works before and after SDK generation.

  After generating your SDK, add tests for its actual API operations. The
  post-generation script creates a starter test per API module in
  `test/unit/`, and the pattern looks like:

      test "gets a user", %{bypass: bypass} do
        MockServer.expect_get(bypass, "/users/1", 200, %{id: 1})
        conn = MySDK.Connection.new(base_url: MockServer.url(bypass))
        assert {:ok, %MySDK.Model.User{id: 1}} = MySDK.Api.Users.get_user(conn, 1)
      end
  """

  use TestCase

  setup do
    bypass = MockServer.setup()
    start_supervised!({Finch, name: ApiIntegrationTest.Finch})

    client =
      Tesla.client(
        [
          {Tesla.Middleware.BaseUrl, MockServer.url(bypass)},
          Tesla.Middleware.EncodeJson,
          Tesla.Middleware.DecodeJson
        ],
        {Tesla.Adapter.Finch, name: ApiIntegrationTest.Finch}
      )

    {:ok, bypass: bypass, client: client}
  end

  describe "GET requests" do
    test "returns decoded response body", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/users/1", 200, %{
        id: 1,
        name: "Test User",
        email: "test@example.com"
      })

      assert {:ok, response} = Tesla.get(client, "/users/1")
      assert response.status == 200
      assert response.body["id"] == 1
      assert response.body["name"] == "Test User"
    end

    test "propagates error statuses", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/users/999", 404, %{error: "Not found"})

      assert {:ok, response} = Tesla.get(client, "/users/999")
      assert response.status == 404
      assert response.body["error"] == "Not found"
    end

    test "handles 500 responses", %{bypass: bypass, client: client} do
      MockServer.expect_error(bypass, 500)

      assert {:ok, response} = Tesla.get(client, "/anything")
      assert response.status == 500
    end
  end

  describe "POST requests" do
    test "encodes request body as JSON", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/users", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert JSON.decode!(body) == %{"name" => "New User"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, JSON.encode!(%{id: 2, name: "New User"}))
      end)

      assert {:ok, response} = Tesla.post(client, "/users", %{name: "New User"})
      assert response.status == 201
      assert response.body["id"] == 2
    end
  end

  describe "error handling" do
    test "returns an error tuple when the server is down", %{bypass: bypass, client: client} do
      Bypass.down(bypass)

      assert {:error, _reason} = Tesla.get(client, "/users/1")
    end
  end

  describe "fixtures" do
    test "fixture data merges custom attributes" do
      user = Fixtures.fixture(:user, %{name: "Custom"})

      assert user.name == "Custom"
      assert user.email == "test@example.com"
    end

    test "fixture_list generates sequential ids" do
      users = Fixtures.fixture_list(:user, 3)

      assert Enum.map(users, & &1.id) == [1, 2, 3]
    end
  end
end
