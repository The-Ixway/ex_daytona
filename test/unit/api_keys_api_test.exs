defmodule ExDaytona.Api.ApiKeysTest do
  use TestCase, async: true

  alias ExDaytona.Api.ApiKeys
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "list_api_keys/2" do
    test "decodes a list of ApiKeyList structs", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/api-keys", 200, [
        %{name: "ci", permissions: ["read:sandboxes"], value: "dtn_****"}
      ])

      assert {:ok, [%Model.ApiKeyList{name: "ci", permissions: ["read:sandboxes"]}]} =
               ApiKeys.list_api_keys(conn)
    end
  end

  describe "create_api_key/3" do
    test "posts the body and decodes the 201 ApiKeyResponse", %{bypass: bypass, conn: conn} do
      Bypass.expect_once(bypass, "POST", "/api-keys", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"name" => "ci"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, JSON.encode!(%{name: "ci", value: "dtn_secret"}))
      end)

      assert {:ok, %Model.ApiKeyResponse{name: "ci", value: "dtn_secret"}} =
               ApiKeys.create_api_key(conn, %Model.CreateApiKey{name: "ci"})
    end
  end

  describe "delete_api_key/3" do
    test "a 204 mapped as passthrough returns the raw env", %{bypass: bypass, conn: conn} do
      MockServer.expect_delete(bypass, "/api-keys/ci", 204)

      assert {:ok, %Tesla.Env{status: 204}} = ApiKeys.delete_api_key(conn, "ci")
    end
  end
end
