defmodule ExDaytona.QuotaTest do
  use TestCase, async: false

  # async: false — the metering tests set the global :analytics_base_url env.

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Platform
  alias ExDaytona.Quota
  alias ExDaytona.Sandbox

  setup do
    bypass = MockServer.setup()

    {:ok, client} =
      Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass), retry: false)

    {:ok, bypass: bypass, client: client}
  end

  defp overview_body do
    %{
      currentSnapshotUsage: 2,
      totalSnapshotQuota: 10,
      currentVolumeUsage: 5.5,
      totalVolumeQuota: 100,
      regionUsage: [
        %{
          regionId: "us",
          sandboxClass: "small",
          currentCpuUsage: 4,
          totalCpuQuota: 64,
          currentMemoryUsage: 8,
          totalMemoryQuota: 128,
          currentDiskUsage: 50,
          totalDiskQuota: 1000,
          currentGpuUsage: 0,
          totalGpuQuota: 0,
          maxCpuPerSandbox: 4,
          maxMemoryPerSandbox: 8,
          maxDiskPerSandbox: 10,
          allowedGpuTypes: []
        },
        %{
          regionId: "eu",
          sandboxClass: "large",
          currentCpuUsage: 10,
          totalCpuQuota: 32
        }
      ]
    }
  end

  describe "Quota.overview/2" do
    test "normalizes gauges and region-class rows", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/organizations/org-1/usage", 200, overview_body())

      assert {:ok, overview} = Quota.overview(client, "org-1")

      assert overview.snapshots == %{used: 2, total: 10}
      assert overview.volumes == %{used: 5.5, total: 100}

      assert [us, eu] = overview.regions
      assert us.region_id == "us"
      assert us.sandbox_class == "small"
      assert us.cpu == %{used: 4, total: 64}
      assert us.memory == %{used: 8, total: 128}
      assert us.max_per_sandbox == %{cpu: 4, memory: 8, disk: 10}
      assert us.allowed_gpu_types == []

      # sparse provider rows normalize with nils intact
      assert eu.cpu == %{used: 10, total: 32}
      assert eu.memory == %{used: nil, total: nil}
    end
  end

  describe "Quota.headroom/3" do
    test "computes remaining capacity per dimension", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/organizations/org-1/usage", 200, overview_body())

      assert {:ok, headroom} = Quota.headroom(client, "org-1", region: "us", class: "small")

      assert headroom == %{cpu: 60, memory: 120, disk: 950, gpu: 0}
    end

    test "unknown combination lists the known ones", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/organizations/org-1/usage", 200, overview_body())

      assert {:error, %Error{code: "NOT_FOUND", message: message}} =
               Quota.headroom(client, "org-1", region: "mars", class: "xl")

      assert message =~ "us/small"
      assert message =~ "eu/large"
    end
  end

  describe "Quota.limits/2" do
    test "normalizes org maxima and rate limits", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/organizations/org-1", 200, %{
        id: "org-1",
        maxCpuPerSandbox: 4,
        maxMemoryPerSandbox: 8,
        maxDiskPerSandbox: 10,
        maxSecretsPerSandbox: 20,
        secretQuota: 100,
        sandboxCreateRateLimit: 30,
        sandboxCreateRateLimitTtlSeconds: 60,
        sandboxLifecycleRateLimit: 100,
        sandboxLifecycleRateLimitTtlSeconds: 60,
        authenticatedRateLimit: 1000,
        authenticatedRateLimitTtlSeconds: 60
      })

      assert {:ok, limits} = Quota.limits(client, "org-1")

      assert limits.max_cpu_per_sandbox == 4
      assert limits.secret_quota == 100
      assert limits.sandbox_create_rate_limit == %{limit: 30, ttl_seconds: 60}
      assert limits.authenticated_rate_limit == %{limit: 1000, ttl_seconds: 60}
    end
  end

  describe "Sandbox.list label-map ergonomics" do
    test "a labels map is JSON-encoded into the filter", %{bypass: bypass, client: client} do
      MockServer.expect_once(bypass, "GET", "/sandbox", fn conn ->
        labels = URI.decode_query(conn.query_string)["labels"]
        assert JSON.decode!(labels) == %{"my-app/tenant" => "user-123"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{items: [%{id: "sb-1"}]}))
      end)

      assert {:ok, %{items: [%Model.SandboxListItem{id: "sb-1"}]}} =
               Sandbox.list(client, labels: %{"my-app/tenant" => "user-123"})
    end

    test "a pre-encoded labels string passes through unchanged", %{
      bypass: bypass,
      client: client
    } do
      MockServer.expect_once(bypass, "GET", "/sandbox", fn conn ->
        assert URI.decode_query(conn.query_string)["labels"] == ~s({"k":"v"})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{items: []}))
      end)

      assert {:ok, %{items: []}} = Sandbox.list(client, labels: ~s({"k":"v"}))
    end
  end

  describe "Platform metering" do
    setup %{bypass: bypass} do
      # Point the analytics connection at the same mock server
      Application.put_env(:ex_daytona, :analytics_base_url, MockServer.url(bypass))
      on_exit(fn -> Application.delete_env(:ex_daytona, :analytics_base_url) end)
      :ok
    end

    test "usage_aggregated normalizes the rollup", %{bypass: bypass, client: client} do
      MockServer.expect_once(bypass, "GET", "/organization/org-1/usage/aggregated", fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["from"] == "2026-08-01T00:00:00Z"
        assert query["to"] == "2026-09-01T00:00:00Z"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!(%{
            sandboxCount: 12,
            totalCPUSeconds: 3600.5,
            totalRAMGBSeconds: 7200,
            totalDiskGBSeconds: 90_000,
            totalPrice: 1.23
          })
        )
      end)

      assert {:ok, usage} =
               Platform.usage_aggregated(
                 client,
                 "org-1",
                 "2026-08-01T00:00:00Z",
                 "2026-09-01T00:00:00Z"
               )

      assert usage.sandbox_count == 12
      assert usage.cpu_seconds == 3600.5
      assert usage.price == 1.23
      refute Map.has_key?(usage, :sandbox_id)
    end

    test "usage_per_sandbox returns per-sandbox rows for scope rollups", %{
      bypass: bypass,
      client: client
    } do
      MockServer.expect_get(bypass, "/organization/org-1/usage/sandbox", 200, [
        %{sandboxId: "sb-1", totalCPUSeconds: 100, totalPrice: 0.1},
        %{sandboxId: "sb-2", totalCPUSeconds: 200, totalPrice: 0.2}
      ])

      assert {:ok, [row1, row2]} =
               Platform.usage_per_sandbox(client, "org-1", "2026-08-01", "2026-09-01")

      assert row1.sandbox_id == "sb-1"
      assert row2.cpu_seconds == 200
      # the application-side tenant rollup this enables:
      assert Enum.sum_by([row1, row2], & &1.price) == 0.30000000000000004
    end

    test "usage_chart returns time-series points", %{bypass: bypass, client: client} do
      MockServer.expect_once(bypass, "GET", "/organization/org-1/usage/chart", fn conn ->
        assert URI.decode_query(conn.query_string)["region"] == "us"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!([
            %{time: "2026-08-01T00:00:00Z", cpu: 4, cpuPrice: 0.01, ramGB: 8, diskGB: 50}
          ])
        )
      end)

      assert {:ok, [point]} =
               Platform.usage_chart(client, "org-1", "2026-08-01", "2026-09-01", region: "us")

      assert point.time == "2026-08-01T00:00:00Z"
      assert point.cpu == 4
      assert point.cpu_price == 0.01
    end
  end
end
