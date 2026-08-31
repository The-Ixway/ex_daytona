defmodule ExDaytona.Api.DockerRegistryTest do
  use TestCase, async: true

  alias ExDaytona.Api.DockerRegistry, as: DockerRegistryApi
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "list_registries/2" do
    test "decodes a list of DockerRegistry structs", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/docker-registry", 200, [
        %{id: "reg-1", name: "ghcr", url: "https://ghcr.io", username: "bot"}
      ])

      assert {:ok, [%Model.DockerRegistry{id: "reg-1", url: "https://ghcr.io"}]} =
               DockerRegistryApi.list_registries(conn)
    end
  end

  describe "get_registry/3" do
    test "decodes a single DockerRegistry", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/docker-registry/reg-1", 200, %{id: "reg-1", name: "ghcr"})

      assert {:ok, %Model.DockerRegistry{id: "reg-1", name: "ghcr"}} =
               DockerRegistryApi.get_registry(conn, "reg-1")
    end
  end
end
