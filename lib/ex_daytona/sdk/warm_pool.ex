defmodule ExDaytona.WarmPool do
  @moduledoc """
  Warm pools: pre-created sandboxes for instant `Sandbox.create/2`.

  A warm pool keeps a number of sandboxes pre-provisioned from a snapshot;
  a matching `ExDaytona.Sandbox.create/2` is then fulfilled from the pool
  in milliseconds instead of provisioning from scratch — the latency lever
  for interactive products:

      {:ok, snapshot} = ExDaytona.Snapshot.build(client, "my-app-base", image)

      {:ok, pool} = ExDaytona.WarmPool.create(client, snapshot: "my-app-base", size: 5)

      # Creates that match the pool's snapshot (and target) draw from it:
      {:ok, sandbox} = ExDaytona.Sandbox.create(client, snapshot: "my-app-base")

      {:ok, pool} = ExDaytona.WarmPool.resize(client, pool.id, 10)
      :ok = ExDaytona.WarmPool.delete(client, pool.id)

  Pool entries count toward the organization's quota
  (`ExDaytona.Quota.overview/2`) — size pools accordingly.
  """

  alias ExDaytona.Api
  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model

  @doc """
  Create a warm pool.

  ## Options

  - `:snapshot` (required) — the snapshot to pre-provision from
  - `:size` (required) — how many sandboxes to keep warm
  - `:target` — region target (server default when omitted)

  Returns `{:ok, %ExDaytona.Model.WarmPool{}}` — `currentSize` reports
  how many entries are warm right now.
  """
  @spec create(Client.t(), keyword()) :: {:ok, Model.WarmPool.t()} | {:error, Error.t()}
  def create(%Client{} = client, opts) do
    request = %Model.CreateWarmPool{
      snapshot: Keyword.fetch!(opts, :snapshot),
      pool: Keyword.fetch!(opts, :size),
      target: opts[:target]
    }

    Error.normalize(Api.WarmPools.create_warm_pool(client.conn, request, response: :full))
  end

  @doc """
  List the organization's warm pools as `ExDaytona.Model.WarmPool`
  structs.
  """
  @spec list(Client.t()) :: {:ok, [Model.WarmPool.t()]} | {:error, Error.t()}
  def list(%Client{} = client) do
    with {:ok, pools} <-
           Error.normalize(Api.WarmPools.list_warm_pools(client.conn, response: :full)) do
      {:ok, List.wrap(pools)}
    end
  end

  @doc """
  Change a warm pool's size. Returns the updated
  `ExDaytona.Model.WarmPool`.
  """
  @spec resize(Client.t(), String.t(), non_neg_integer()) ::
          {:ok, Model.WarmPool.t()} | {:error, Error.t()}
  def resize(%Client{} = client, pool_id, size)
      when is_binary(pool_id) and is_integer(size) and size >= 0 do
    request = %Model.UpdateWarmPool{pool: size}

    Error.normalize(Api.WarmPools.update_warm_pool(client.conn, pool_id, request, response: :full))
  end

  @doc """
  Delete a warm pool (its warm entries are released). Returns `:ok`.
  """
  @spec delete(Client.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(%Client{} = client, pool_id) when is_binary(pool_id) do
    with {:ok, _} <-
           Error.normalize(Api.WarmPools.delete_warm_pool(client.conn, pool_id, response: :full)) do
      :ok
    end
  end
end
