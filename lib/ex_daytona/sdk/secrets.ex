defmodule ExDaytona.Secrets do
  @moduledoc """
  Vault-backed secrets: management, sandbox bindings, and resolution.

  Secrets hold sensitive values server-side; sandboxes mount them as
  environment variables through *bindings* (`%{"ENV_VAR" => "secret-name"}`),
  so plaintext never travels through ordinary sandbox metadata:

      {:ok, secret} = ExDaytona.Secrets.create(client, "db-prod", "s3cr3t")

      {:ok, sandbox} =
        ExDaytona.Sandbox.create(client, secrets: [%{"DB_PASSWORD" => "db-prod"}])

      # or later, replacing the mounted set:
      {:ok, _} = ExDaytona.Secrets.set_sandbox_bindings(sandbox, [%{"DB_PASSWORD" => "db-prod"}])

  Every value-bearing input and result renders redacted under
  `inspect/1` — resolved plaintext is reachable only by reading struct
  fields explicitly.
  """

  alias ExDaytona.Api
  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Sandbox

  @doc """
  Create a secret. Options: `:description`, `:hosts` (list of hosts the
  secret may be exposed to).
  """
  @spec create(Client.t(), String.t(), String.t(), keyword()) ::
          {:ok, Model.Secret.t()} | {:error, Error.t()}
  def create(%Client{} = client, name, value, opts \\ [])
      when is_binary(name) and is_binary(value) do
    request = %Model.CreateSecret{
      name: name,
      value: value,
      description: opts[:description],
      hosts: opts[:hosts]
    }

    Error.normalize(Api.Secret.create_secret(client.conn, request, response: :full))
  end

  @doc """
  Fetch a secret's metadata by id (values are never returned here).
  """
  @spec get(Client.t(), String.t()) :: {:ok, Model.Secret.t()} | {:error, Error.t()}
  def get(%Client{} = client, secret_id) when is_binary(secret_id) do
    Error.normalize(Api.Secret.get_secret(client.conn, secret_id, response: :full))
  end

  @doc """
  List secrets with pagination. Accepts `:cursor`, `:limit`, `:name`,
  `:sort`, `:order`; returns
  `{:ok, %{items: [%ExDaytona.Model.Secret{}], next_cursor: cursor, total: n}}`.
  """
  @spec list(Client.t(), keyword()) ::
          {:ok,
           %{
             items: [Model.Secret.t()],
             next_cursor: String.t() | nil,
             total: non_neg_integer() | nil
           }}
          | {:error, Error.t()}
  def list(%Client{} = client, opts \\ []) do
    with {:ok, %Model.ListSecretsResponse{items: items, nextCursor: cursor, total: total}} <-
           Error.normalize(Api.Secret.list_secrets_paginated(client.conn, opts ++ [response: :full])) do
      {:ok, %{items: items || [], next_cursor: cursor, total: total}}
    end
  end

  @doc """
  Update a secret. Options: `:value`, `:description`, `:hosts` — only the
  given fields change.
  """
  @spec update(Client.t(), String.t(), keyword()) ::
          {:ok, Model.Secret.t()} | {:error, Error.t()}
  def update(%Client{} = client, secret_id, opts) when is_binary(secret_id) and opts != [] do
    request = %Model.UpdateSecret{
      value: opts[:value],
      description: opts[:description],
      hosts: opts[:hosts]
    }

    Error.normalize(Api.Secret.update_secret(client.conn, secret_id, request, response: :full))
  end

  @doc """
  Delete a secret. Returns `:ok`.
  """
  @spec delete(Client.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(%Client{} = client, secret_id) when is_binary(secret_id) do
    with {:ok, _} <-
           Error.normalize(Api.Secret.delete_secret(client.conn, secret_id, response: :full)) do
      :ok
    end
  end

  @doc """
  Replace the sandbox's mounted secret set with `bindings` — a list of
  single-entry maps `%{"ENV_VAR" => "secret-name"}`. Pass `[]` to detach
  all secrets. Returns the updated sandbox.
  """
  @spec set_sandbox_bindings(Sandbox.t(), [map()]) :: {:ok, Sandbox.t()} | {:error, Error.t()}
  def set_sandbox_bindings(%Sandbox{client: client, info: %{id: id}} = sandbox, bindings)
      when is_list(bindings) do
    request = %Model.UpdateSandboxSecrets{secrets: bindings}

    with {:ok, %Model.Sandbox{} = info} <-
           Error.normalize(Api.Sandbox.update_sandbox_secrets(client.conn, id, request, response: :full)) do
      {:ok, %{sandbox | info: info}}
    end
  end

  @doc """
  Resolve the sandbox's secret bindings. Returns
  `ExDaytona.Model.ResolveSandboxSecrets200ResponseInner` structs whose
  `value` fields are **redacted under `inspect/1`** — plaintext is only
  reachable by reading `.value` explicitly.
  """
  @spec resolve(Sandbox.t()) ::
          {:ok, [Model.ResolveSandboxSecrets200ResponseInner.t()]} | {:error, Error.t()}
  def resolve(%Sandbox{client: client, info: %{id: id}}) do
    with {:ok, resolved} <-
           Error.normalize(Api.Sandbox.resolve_sandbox_secrets(client.conn, id, response: :full)) do
      {:ok, List.wrap(resolved)}
    end
  end
end
