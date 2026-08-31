defmodule ExDaytona.Api.ServerTest do
  use TestCase, async: true

  alias ExDaytona.Api.Server
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "update_env/3" do
    test "posts set/unset vars and decodes the untyped response to a plain map", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_once(bypass, "POST", "/env", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"set" => %{"FOO" => "bar"}, "unset" => ["OLD"]} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{}))
      end)

      request = %Model.UpdateEnvRequest{set: %{"FOO" => "bar"}, unset: ["OLD"]}

      # {200, %{}} in the mapping — no model, plain JSON decode.
      assert {:ok, response} = Server.update_env(conn, request)
      assert response == %{}
    end
  end

  describe "initialize/3" do
    test "posts the token", %{bypass: bypass, conn: conn} do
      MockServer.expect_once(bypass, "POST", "/init", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"token" => "tok"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{}))
      end)

      assert {:ok, response} = Server.initialize(conn, %Model.InitializeRequest{token: "tok"})
      assert response == %{}
    end
  end
end
