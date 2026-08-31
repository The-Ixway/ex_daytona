defmodule ExDaytona.Api.SecretTest do
  use TestCase, async: true

  alias ExDaytona.Api.Secret, as: SecretApi
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "list_secrets_paginated/2" do
    test "decodes the paginated wrapper and its items", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/secret/paginated", 200, %{
        items: [%{id: "sec-1", name: "API_TOKEN", hosts: ["example.com"]}],
        total: 1
      })

      assert {:ok, %Model.ListSecretsResponse{items: [item], total: 1}} =
               SecretApi.list_secrets_paginated(conn)

      assert %Model.Secret{id: "sec-1", name: "API_TOKEN"} = item
    end
  end

  describe "create_secret/3" do
    test "posts the body and decodes the 201 Secret", %{bypass: bypass, conn: conn} do
      Bypass.expect_once(bypass, "POST", "/secret", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"name" => "API_TOKEN"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, JSON.encode!(%{id: "sec-new", name: "API_TOKEN"}))
      end)

      assert {:ok, %Model.Secret{id: "sec-new"}} =
               SecretApi.create_secret(conn, %Model.CreateSecret{name: "API_TOKEN"})
    end
  end

  describe "update_secret/4" do
    test "PATCHes the secret", %{bypass: bypass, conn: conn} do
      Bypass.expect_once(bypass, "PATCH", "/secret/sec-1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "sec-1", name: "API_TOKEN"}))
      end)

      assert {:ok, %Model.Secret{id: "sec-1"}} =
               SecretApi.update_secret(conn, "sec-1", %Model.UpdateSecret{})
    end
  end
end
