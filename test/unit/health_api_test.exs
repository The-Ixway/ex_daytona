defmodule ExDaytona.Api.HealthTest do
  use TestCase, async: true

  alias ExDaytona.Api.Health
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "check/2 (GET /health/ready)" do
    test "decodes a healthy response", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/health/ready", 200, %{
        status: "ok",
        info: %{database: %{status: "up"}}
      })

      assert {:ok, %Model.Check200Response{status: "ok"}} = Health.check(conn)
    end

    test "a spec-declared 503 decodes into the unhealthy model (as :ok)", %{bypass: bypass} do
      # retry: false — 503 on a GET is normally retried by the Retry
      # middleware, which would re-hit the expect_once expectation.
      conn = Connection.new(base_url: MockServer.url(bypass), retry: false)

      MockServer.expect_get(bypass, "/health/ready", 503, %{
        status: "error",
        error: %{redis: %{status: "down"}}
      })

      assert {:ok, %Model.Check503Response{status: "error"}} = Health.check(conn)
    end
  end

  describe "live/2 (GET /health)" do
    test "returns the raw env (200 is mapped as passthrough)", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/health", 200, %{status: "ok"})

      assert {:ok, %Tesla.Env{status: 200}} = Health.live(conn)
    end
  end
end
