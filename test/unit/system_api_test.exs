defmodule ExDaytona.Api.SystemTest do
  use TestCase, async: true

  alias ExDaytona.Api.System, as: SystemApi
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_system_metrics/2" do
    test "decodes the SystemMetrics", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/system/metrics", 200, %{
        cpuCount: 4,
        cpuUsedPct: 12.5,
        memTotal: 8_589_934_592,
        memUsed: 1_073_741_824
      })

      assert {:ok, %Model.SystemMetrics{cpuCount: 4, cpuUsedPct: 12.5}} =
               SystemApi.get_system_metrics(conn)
    end
  end
end
