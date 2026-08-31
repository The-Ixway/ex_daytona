defmodule ExDaytona.AnalyticsTest do
  use TestCase, async: false

  alias ExDaytona.Analytics
  alias ExDaytona.Api.Usage
  alias ExDaytona.Model

  # async: false — these tests mutate the :analytics_base_url application
  # env, which is global state.

  setup do
    original = Application.fetch_env(:ex_daytona, :analytics_base_url)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:ex_daytona, :analytics_base_url, value)
        :error -> Application.delete_env(:ex_daytona, :analytics_base_url)
      end
    end)

    :ok
  end

  describe "connection/1" do
    test "requests go to the configured analytics base URL" do
      bypass = MockServer.setup()
      Application.put_env(:ex_daytona, :analytics_base_url, MockServer.url(bypass))

      MockServer.expect_get(bypass, "/organization/org-1/usage/aggregated", 200, %{
        total_cost: "1.23"
      })

      conn = Analytics.connection()

      assert {:ok, %Model.ModelsAggregatedUsage{}} =
               Usage.get_organization_usage_aggregated(
                 conn,
                 "org-1",
                 "2026-01-01T00:00:00Z",
                 "2026-02-01T00:00:00Z"
               )
    end

    test "defaults to the production analytics base URL" do
      Application.delete_env(:ex_daytona, :analytics_base_url)

      middleware = Tesla.Client.middleware(Analytics.connection())

      assert {Tesla.Middleware.BaseUrl, "https://analytics.app.daytona.io"} in middleware
    end

    test "forwards options like bearer_token to the connection" do
      bypass = MockServer.setup()
      Application.put_env(:ex_daytona, :analytics_base_url, MockServer.url(bypass))

      Bypass.expect_once(bypass, "GET", "/organization/org-1/usage/aggregated", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer an-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{total_cost: "0"}))
      end)

      conn = Analytics.connection(bearer_token: "an-token")

      assert {:ok, %Model.ModelsAggregatedUsage{}} =
               Usage.get_organization_usage_aggregated(
                 conn,
                 "org-1",
                 "2026-01-01T00:00:00Z",
                 "2026-02-01T00:00:00Z"
               )
    end
  end
end
