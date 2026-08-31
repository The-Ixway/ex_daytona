defmodule ExDaytona.Api.ConfigTest do
  use TestCase, async: true

  alias ExDaytona.Api.Config
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_config/2" do
    test "decodes the DaytonaConfiguration", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/config", 200, %{
        environment: "production",
        dashboardUrl: "https://app.daytona.io",
        analyticsApiUrl: "https://analytics.app.daytona.io"
      })

      assert {:ok,
              %Model.DaytonaConfiguration{
                environment: "production",
                analyticsApiUrl: "https://analytics.app.daytona.io"
              }} = Config.get_config(conn)
    end
  end
end
