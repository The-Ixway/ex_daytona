defmodule ExDaytona.Api.TelemetryTest do
  use TestCase, async: true

  alias ExDaytona.Api.Telemetry, as: TelemetryApi
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_organization_sandbox_logs/6" do
    test "sends from/to plus filters as query params and decodes log entries", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_once(
        bypass,
        "GET",
        "/organization/org-1/sandbox/sb-1/telemetry/logs",
        fn conn ->
          query = URI.decode_query(conn.query_string)
          assert query["from"] == "2026-01-01T00:00:00Z"
          assert query["to"] == "2026-02-01T00:00:00Z"
          assert query["severity"] == "error"

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            JSON.encode!([%{body: "boom", severityText: "ERROR", serviceName: "sandbox"}])
          )
        end
      )

      assert {:ok, [%Model.ModelsLogEntry{body: "boom", severityText: "ERROR"}]} =
               TelemetryApi.get_organization_sandbox_logs(
                 conn,
                 "org-1",
                 "sb-1",
                 "2026-01-01T00:00:00Z",
                 "2026-02-01T00:00:00Z",
                 severity: "error"
               )
    end
  end
end
