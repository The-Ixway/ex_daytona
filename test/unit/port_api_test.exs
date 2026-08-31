defmodule ExDaytona.Api.PortTest do
  use TestCase, async: true

  alias ExDaytona.Api.Port, as: PortApi
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_ports/2" do
    test "decodes the PortList", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/port", 200, %{ports: [4000, 8080]})

      assert {:ok, %Model.PortList{ports: [4000, 8080]}} = PortApi.get_ports(conn)
    end
  end

  describe "is_port_in_use/3" do
    test "interpolates the port into the path and decodes the flag", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_get(bypass, "/port/8080/in-use", 200, %{isInUse: true})

      assert {:ok, %Model.IsPortInUseResponse{isInUse: true}} =
               PortApi.is_port_in_use(conn, 8080)
    end
  end
end
