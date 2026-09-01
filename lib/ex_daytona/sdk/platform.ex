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

  @doc """
  The organization's usage/quota overview (current usage vs. limits).
  """
  @spec usage_overview(Client.t(), String.t()) ::
          {:ok, Model.OrganizationUsageOverview.t()} | {:error, Error.t()}
  def usage_overview(%Client{} = client, organization_id) when is_binary(organization_id) do
    Error.normalize(Api.Organizations.get_organization_usage_overview(client.conn, organization_id, response: :full))
  end
end
