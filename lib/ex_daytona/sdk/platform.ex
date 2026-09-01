defmodule ExDaytona.Platform do
  @moduledoc """
  Read-only platform lookups commonly needed before creating a sandbox:
  organizations, regions, sandbox classes, snapshots, and usage/quota.

      {:ok, regions} = ExDaytona.Platform.regions(client)
      {:ok, classes} = ExDaytona.Platform.sandbox_classes(client, org_id)
      {:ok, %{items: snapshots}} = ExDaytona.Platform.snapshots(client, limit: 10)

  All helpers return normalized generated models with facade error
  handling. Note that `organizations/1` requires JWT authentication —
  plain API keys receive a 401 from the provider.
  """

  alias ExDaytona.Api
  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model

  @doc """
  List the caller's organizations.

  > #### JWT only {: .warning}
  >
  > The provider rejects API-key authentication on this endpoint (401
  > "Invalid credentials"). Sandbox-scoped code can read its own
  > organization id from `sandbox.info.organizationId` instead.
  """
  @spec organizations(Client.t()) :: {:ok, [Model.Organization.t()]} | {:error, Error.t()}
  def organizations(%Client{} = client) do
    with {:ok, orgs} <-
           Error.normalize(Api.Organizations.list_organizations(client.conn, response: :full)) do
      {:ok, List.wrap(orgs)}
    end
  end

  @doc """
  List the regions available to the caller.
  """
  @spec regions(Client.t()) :: {:ok, [Model.Region.t()]} | {:error, Error.t()}
  def regions(%Client{} = client) do
    with {:ok, regions} <-
           Error.normalize(Api.Organizations.list_available_regions(client.conn, response: :full)) do
      {:ok, List.wrap(regions)}
    end
  end

  @doc """
  List the sandbox classes (with GPU availability) an organization can
  use.
  """
  @spec sandbox_classes(Client.t(), String.t()) ::
          {:ok, [Model.AvailableSandboxClass.t()]} | {:error, Error.t()}
  def sandbox_classes(%Client{} = client, organization_id) when is_binary(organization_id) do
    with {:ok, classes} <-
           Error.normalize(
             Api.Organizations.list_available_sandbox_classes(client.conn, organization_id, response: :full)
           ) do
      {:ok, List.wrap(classes)}
    end
  end

  @doc """
  List snapshots with pagination. Accepts `:page`, `:limit`, `:name`,
  `:sort`, `:order`; returns
  `{:ok, %{items: [...], page: p, total: n, total_pages: tp}}`.
  """
  @spec snapshots(Client.t(), keyword()) ::
          {:ok,
           %{
             items: [Model.SnapshotDto.t()],
             page: non_neg_integer() | nil,
             total: non_neg_integer() | nil,
             total_pages: non_neg_integer() | nil
           }}
          | {:error, Error.t()}
  def snapshots(%Client{} = client, opts \\ []) do
    with {:ok, %Model.PaginatedSnapshots{} = page} <-
           Error.normalize(Api.Snapshots.get_all_snapshots(client.conn, opts ++ [response: :full])) do
      {:ok,
       %{
         items: page.items || [],
         page: page.page,
         total: page.total,
         total_pages: page.totalPages
       }}
    end
  end

  @doc """
  Fetch one snapshot by id or name.
  """
  @spec snapshot(Client.t(), String.t()) :: {:ok, Model.SnapshotDto.t()} | {:error, Error.t()}
  def snapshot(%Client{} = client, id_or_name) when is_binary(id_or_name) do
    Error.normalize(Api.Snapshots.get_snapshot(client.conn, id_or_name, response: :full))
  end

  ## Metering (analytics API) -------------------------------------------------

  @doc """
  Aggregated metered usage for the organization over `[from, to]`
  (ISO 8601 timestamps), normalized to snake_case:
  `{:ok, %{sandbox_count, cpu_seconds, ram_gb_seconds, disk_gb_seconds,
  gpu_seconds, price, first_start, last_end}}`.

  Served by the analytics API (its own base URL — the connection is
  derived automatically; override via
  `config :ex_daytona, :analytics_base_url`).
  """
  @spec usage_aggregated(Client.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def usage_aggregated(%Client{} = client, organization_id, from, to)
      when is_binary(organization_id) do
    with {:ok, %Model.ModelsAggregatedUsage{} = usage} <-
           Error.normalize(
             Api.Usage.get_organization_usage_aggregated(
               analytics_conn(client),
               organization_id,
               from,
               to,
               response: :full
             )
           ) do
      {:ok, normalize_usage(usage)}
    end
  end

  @doc """
  Per-sandbox metered usage over `[from, to]` — the primitive for
  rolling usage up into application-defined scopes (attribute sandboxes
  with labels at create time, list them with
  `ExDaytona.Sandbox.list(client, labels: %{...})`, then sum their rows
  here). Returns `{:ok, [%{sandbox_id: id, cpu_seconds: n, ...}]}`.
  """
  @spec usage_per_sandbox(Client.t(), String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def usage_per_sandbox(%Client{} = client, organization_id, from, to)
      when is_binary(organization_id) do
    with {:ok, rows} <-
           Error.normalize(
             Api.Usage.get_organization_usage_per_sandbox(
               analytics_conn(client),
               organization_id,
               from,
               to,
               response: :full
             )
           ) do
      {:ok, rows |> List.wrap() |> Enum.map(&normalize_usage/1)}
    end
  end

  @doc """
  Usage over time as chart points (`:region` option narrows to one
  region). Each point:
  `%{time, cpu, cpu_price, ram_gb, ram_price, disk_gb, disk_price}`.
  """
  @spec usage_chart(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def usage_chart(%Client{} = client, organization_id, from, to, opts \\ [])
      when is_binary(organization_id) do
    api_opts = Keyword.take(opts, [:region]) ++ [response: :full]

    with {:ok, points} <-
           Error.normalize(
             Api.Usage.get_organization_usage_chart(
               analytics_conn(client),
               organization_id,
               from,
               to,
               api_opts
             )
           ) do
      {:ok,
       points
       |> List.wrap()
       |> Enum.map(fn %Model.ModelsUsageChartPoint{} = point ->
         %{
           time: point.time,
           cpu: point.cpu,
           cpu_price: point.cpuPrice,
           ram_gb: point.ramGB,
           ram_price: point.ramPrice,
           disk_gb: point.diskGB,
           disk_price: point.diskPrice
         }
       end)}
    end
  end

  defp analytics_conn(%Client{} = client) do
    ExDaytona.Analytics.connection([bearer_token: client.api_key] ++ client.options)
  end

  defp normalize_usage(usage) do
    %{
      sandbox_count: Map.get(usage, :sandboxCount),
      sandbox_id: Map.get(usage, :sandboxId),
      cpu_seconds: Map.get(usage, :totalCPUSeconds),
      ram_gb_seconds: Map.get(usage, :totalRAMGBSeconds),
      disk_gb_seconds: Map.get(usage, :totalDiskGBSeconds),
      gpu_seconds: Map.get(usage, :totalGPUSeconds),
      price: Map.get(usage, :totalPrice),
      first_start: Map.get(usage, :firstStart),
      last_end: Map.get(usage, :lastEnd)
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  The organization's usage/quota overview (current usage vs. limits).
  """
  @spec usage_overview(Client.t(), String.t()) ::
          {:ok, Model.OrganizationUsageOverview.t()} | {:error, Error.t()}
  def usage_overview(%Client{} = client, organization_id) when is_binary(organization_id) do
    Error.normalize(Api.Organizations.get_organization_usage_overview(client.conn, organization_id, response: :full))
  end
end
