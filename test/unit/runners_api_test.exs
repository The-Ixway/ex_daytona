defmodule ExDaytona.Api.RunnersTest do
  use TestCase, async: true

  alias ExDaytona.Api.Runners
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "list_runners/2" do
    test "decodes a list of Runner structs", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/runners", 200, [
        %{id: "run-1", class: "small", cpu: 4}
      ])

      assert {:ok, [%Model.Runner{id: "run-1", cpu: 4}]} = Runners.list_runners(conn)
    end
  end

  describe "get_runner_by_id/3" do
    test "decodes a single Runner", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/runners/run-1", 200, %{id: "run-1", class: "small"})

      assert {:ok, %Model.Runner{id: "run-1"}} = Runners.get_runner_by_id(conn, "run-1")
    end
  end

  describe "get_snapshot_refs_for_authenticated_runner/2" do
    # Regression: {200, []} mappings (arrays of primitives) crashed the
    # deserializer before the request_builder template learned to plain-JSON
    # decode them.
    test "an array-of-strings response decodes to a plain list", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/runners/me/snapshots", 200, [
        "docker.io/library/ubuntu:22.04",
        "docker.io/library/python:3.12"
      ])

      assert {:ok, refs} = Runners.get_snapshot_refs_for_authenticated_runner(conn)
      assert refs == ["docker.io/library/ubuntu:22.04", "docker.io/library/python:3.12"]
    end
  end
end
