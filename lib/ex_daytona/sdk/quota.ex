defmodule ExDaytona.Quota do
  @moduledoc """
  Normalized read access to organization quotas, limits, and current
  usage — the primitives an application needs to build its own
  admission control or per-tenant limit logic on top of Daytona's
  org-level enforcement.

      {:ok, overview} = ExDaytona.Quota.overview(client, org_id)
      # => %{snapshots: %{used: 2, total: 10},
      #      volumes: %{used: 0.0, total: 100.0},
      #      regions: [%{region_id: "us", sandbox_class: "small",
      #                  cpu: %{used: 4, total: 64}, memory: %{...}, ...}]}

      {:ok, headroom} = ExDaytona.Quota.headroom(client, org_id, region: "us", class: "small")
      # => %{cpu: 60, memory: 120, disk: 800, gpu: 0}

      {:ok, limits} = ExDaytona.Quota.limits(client, org_id)
      # => per-sandbox maxima, secret quota, create/lifecycle rate limits

  The SDK deliberately ships **no** per-user limit enforcement — these
  are read primitives. An application imposing finer-grained limits than
  the organization's (e.g. per end-user of a SaaS product) can combine
  them with label-scoped sandbox listing
  (`ExDaytona.Sandbox.list(client, labels: %{"my-app/tenant" => id})`)
  and the metering rollups in `ExDaytona.Platform`. Note that any such
  application-side check is advisory (check-then-act) — Daytona enforces
  only the organization-level quota.
  """

  alias ExDaytona.Api
  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model

  @typedoc "A used-vs-total pair for one resource dimension."
  @type gauge :: %{used: number() | nil, total: number() | nil}

  @typedoc "Quota and usage for one region × sandbox-class combination."
  @type region_class :: %{
          region_id: String.t() | nil,
          sandbox_class: String.t() | nil,
          cpu: gauge(),
          memory: gauge(),
          disk: gauge(),
          gpu: gauge(),
          max_per_sandbox: %{cpu: number() | nil, memory: number() | nil, disk: number() | nil},
          allowed_gpu_types: [String.t()]
        }

  @doc """
  The organization's quota/usage overview, normalized: snapshot and
  volume gauges plus one `t:region_class/0` entry per region ×
  sandbox-class.
  """
  @spec overview(Client.t(), String.t()) ::
          {:ok, %{snapshots: gauge(), volumes: gauge(), regions: [region_class()]}}
          | {:error, Error.t()}
  def overview(%Client{} = client, organization_id) when is_binary(organization_id) do
    with {:ok, %Model.OrganizationUsageOverview{} = raw} <-
           Error.normalize(
             Api.Organizations.get_organization_usage_overview(client.conn, organization_id, response: :full)
           ) do
      {:ok,
       %{
         snapshots: %{used: raw.currentSnapshotUsage, total: raw.totalSnapshotQuota},
         volumes: %{used: raw.currentVolumeUsage, total: raw.totalVolumeQuota},
         regions: Enum.map(List.wrap(raw.regionUsage), &normalize_region/1)
       }}
    end
  end

  @doc """
  Remaining capacity for one region × sandbox-class:
  `{:ok, %{cpu: n, memory: n, disk: n, gpu: n}}` (each
  `total - used`, `nil` when the provider reports no quota for the
  dimension). Returns a `NOT_FOUND`-coded error when the organization
  has no quota row for the combination.
  """
  @spec headroom(Client.t(), String.t(), keyword()) ::
          {:ok,
           %{
             cpu: number() | nil,
             memory: number() | nil,
             disk: number() | nil,
             gpu: number() | nil
           }}
          | {:error, Error.t()}
  def headroom(%Client{} = client, organization_id, opts) do
    region = Keyword.fetch!(opts, :region)
    class = Keyword.fetch!(opts, :class)

    with {:ok, %{regions: regions}} <- overview(client, organization_id) do
      case Enum.find(regions, &(&1.region_id == region and &1.sandbox_class == class)) do
        nil ->
          {:error,
           %Error{
             code: "NOT_FOUND",
             message:
               "no quota row for region #{inspect(region)} / class #{inspect(class)} — " <>
                 "known combinations: " <> known_combinations(regions)
           }}

        row ->
          {:ok,
           %{
             cpu: remaining(row.cpu),
             memory: remaining(row.memory),
             disk: remaining(row.disk),
             gpu: remaining(row.gpu)
           }}
      end
    end
  end

  @doc """
  The organization's limits: per-sandbox resource maxima, secret quota,
  and the create/lifecycle/API rate limits, normalized to snake_case.
  """
  @spec limits(Client.t(), String.t()) ::
          {:ok,
           %{
             max_cpu_per_sandbox: number() | nil,
             max_memory_per_sandbox: number() | nil,
             max_disk_per_sandbox: number() | nil,
             max_secrets_per_sandbox: number() | nil,
             secret_quota: number() | nil,
             sandbox_create_rate_limit: %{limit: number() | nil, ttl_seconds: number() | nil},
             sandbox_lifecycle_rate_limit: %{limit: number() | nil, ttl_seconds: number() | nil},
             authenticated_rate_limit: %{limit: number() | nil, ttl_seconds: number() | nil}
           }}
          | {:error, Error.t()}
  def limits(%Client{} = client, organization_id) when is_binary(organization_id) do
    with {:ok, %Model.Organization{} = org} <-
           Error.normalize(Api.Organizations.get_organization(client.conn, organization_id, response: :full)) do
      {:ok,
       %{
         max_cpu_per_sandbox: org.maxCpuPerSandbox,
         max_memory_per_sandbox: org.maxMemoryPerSandbox,
         max_disk_per_sandbox: org.maxDiskPerSandbox,
         max_secrets_per_sandbox: org.maxSecretsPerSandbox,
         secret_quota: org.secretQuota,
         sandbox_create_rate_limit: %{
           limit: org.sandboxCreateRateLimit,
           ttl_seconds: org.sandboxCreateRateLimitTtlSeconds
         },
         sandbox_lifecycle_rate_limit: %{
           limit: org.sandboxLifecycleRateLimit,
           ttl_seconds: org.sandboxLifecycleRateLimitTtlSeconds
         },
         authenticated_rate_limit: %{
           limit: org.authenticatedRateLimit,
           ttl_seconds: org.authenticatedRateLimitTtlSeconds
         }
       }}
    end
  end

  defp normalize_region(%Model.RegionUsageOverview{} = row) do
    %{
      region_id: row.regionId,
      sandbox_class: row.sandboxClass,
      cpu: %{used: row.currentCpuUsage, total: row.totalCpuQuota},
      memory: %{used: row.currentMemoryUsage, total: row.totalMemoryQuota},
      disk: %{used: row.currentDiskUsage, total: row.totalDiskQuota},
      gpu: %{used: row.currentGpuUsage, total: row.totalGpuQuota},
      max_per_sandbox: %{
        cpu: row.maxCpuPerSandbox,
        memory: row.maxMemoryPerSandbox,
        disk: row.maxDiskPerSandbox
      },
      allowed_gpu_types: List.wrap(row.allowedGpuTypes)
    }
  end

  defp remaining(%{used: used, total: total}) when is_number(used) and is_number(total),
    do: max(total - used, 0)

  defp remaining(_gauge), do: nil

  defp known_combinations(regions) do
    Enum.map_join(regions, ", ", &"#{&1.region_id}/#{&1.sandbox_class}")
  end
end
