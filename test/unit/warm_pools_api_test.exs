defmodule ExDaytona.Api.WarmPoolsTest do
  use TestCase, async: true

  alias ExDaytona.Api.WarmPools
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "list_warm_pools/2" do
    test "decodes a list of WarmPool structs", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/warm-pools", 200, [
        %{id: "wp-1", snapshot: "base", target: 3, currentSize: 2}
      ])

      assert {:ok, [%Model.WarmPool{id: "wp-1", target: 3, currentSize: 2}]} =
               WarmPools.list_warm_pools(conn)
    end
  end

  describe "create_warm_pool/3" do
    test "posts the body and decodes the 201 WarmPool", %{bypass: bypass, conn: conn} do
      MockServer.expect_once(bypass, "POST", "/warm-pools", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"snapshot" => "base"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, JSON.encode!(%{id: "wp-new", snapshot: "base"}))
      end)

      assert {:ok, %Model.WarmPool{id: "wp-new"}} =
               WarmPools.create_warm_pool(conn, %Model.CreateWarmPool{snapshot: "base"})
    end
  end
end
