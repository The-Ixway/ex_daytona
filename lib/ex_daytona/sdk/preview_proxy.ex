defmodule ExDaytona.PreviewProxy do
  @moduledoc """
  Building blocks for a **custom preview proxy** in front of sandbox
  preview traffic.

  Daytona's stock preview URLs go through its proxy; when you run your own
  (custom domains, your own auth, request shaping), your proxy must answer
  the questions Daytona's proxy answers — is this sandbox public, is this
  preview token valid, which sandbox does this signed URL belong to. These
  helpers are those checks:

      # Is the sandbox public (no token needed)?
      {:ok, true} = ExDaytona.PreviewProxy.public?(client, sandbox_id)

      # Validate an x-daytona-preview-token a caller presented
      {:ok, valid?} = ExDaytona.PreviewProxy.valid_token?(client, sandbox_id, token)

      # Resolve a signed preview URL token to its sandbox
      {:ok, sandbox_id} = ExDaytona.PreviewProxy.resolve_signed_token(client, signed_token, 3000)

      # Verify signed tokens locally (no API round-trip per request)
      {:ok, signing_key} = ExDaytona.PreviewProxy.signing_key(client, sandbox_id)

  All functions take the `ExDaytona.Client` so a proxy can hold one
  long-lived client.

  > #### Authentication {: .warning}
  >
  > Most of these endpoints authenticate **proxy infrastructure**, not
  > end users: with a regular user API key they return
  > `403 "Invalid authentication context"` (`access?/2` is the exception
  > — it answers for the key's own principal). Running a custom preview
  > proxy requires credentials provisioned for that purpose (contact
  > Daytona).
  """

  alias ExDaytona.Api
  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model

  @doc """
  Whether the API key's principal has preview access to the sandbox.
  """
  # no_match: the generated @spec for has_sandbox_access claims {:ok,
  # boolean()} but its {200/404, false} passthrough mappings actually
  # return {:ok, Tesla.Env.t()} — the op typespec is computed inside
  # openapi-generator itself, not our vendored templates, so it can't be
  # fixed there. Runtime behavior is covered by unit tests.
  @dialyzer {:no_match, access?: 2}
  @spec access?(Client.t(), String.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def access?(%Client{} = client, sandbox_id) when is_binary(sandbox_id) do
    case Api.Preview.has_sandbox_access(client.conn, sandbox_id) do
      # {404, false} is a declared mapping: not found -> no access
      {:ok, %Tesla.Env{status: 404}} -> {:ok, false}
      other -> bool_result(other)
    end
  end

  @doc """
  Whether the sandbox is public (previews need no auth token).
  """
  @spec public?(Client.t(), String.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def public?(%Client{} = client, sandbox_id) when is_binary(sandbox_id) do
    bool_result(Api.Preview.is_sandbox_public(client.conn, sandbox_id))
  end

  @doc """
  Whether `token` is a valid preview auth token for the sandbox (what a
  caller presents in the `x-daytona-preview-token` header).
  """
  @spec valid_token?(Client.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, Error.t()}
  def valid_token?(%Client{} = client, sandbox_id, token)
      when is_binary(sandbox_id) and is_binary(token) do
    bool_result(Api.Preview.is_valid_auth_token(client.conn, sandbox_id, token))
  end

  @doc """
  Resolve a signed preview URL token (plus the port it was issued for) to
  its sandbox id.
  """
  @spec resolve_signed_token(Client.t(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def resolve_signed_token(%Client{} = client, signed_token, port)
      when is_binary(signed_token) and is_integer(port) do
    with {:ok, %Tesla.Env{body: body}} <-
           Error.normalize(
             Api.Preview.get_sandbox_id_from_signed_preview_url_token(
               client.conn,
               signed_token,
               port
             )
           ) do
      {:ok, extract_string(body, "sandboxId")}
    end
  end

  @doc """
  The sandbox's signing key, for verifying signed preview URL tokens
  locally instead of calling the API per request.
  """
  @spec signing_key(Client.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def signing_key(%Client{} = client, sandbox_id) when is_binary(sandbox_id) do
    with {:ok, %Tesla.Env{body: body}} <-
           Error.normalize(Api.Preview.get_signing_key(client.conn, sandbox_id)) do
      {:ok, extract_string(body, "signingKey")}
    end
  end

  @doc """
  Whether Daytona's interstitial preview warning page is enabled for the
  sandbox's organization (a proxy may want to replicate or skip it).
  """
  @spec preview_warning?(Client.t(), String.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def preview_warning?(%Client{} = client, sandbox_id) when is_binary(sandbox_id) do
    with {:ok, %Model.PreviewWarning{enabled: enabled}} <-
           Error.normalize(Api.Preview.is_preview_warning_enabled(client.conn, sandbox_id)) do
      {:ok, enabled == true}
    end
  end

  # These endpoints are mapped {200, false} (raw env passthrough); the body
  # is a JSON boolean, a bare "true"/"false" string, or an object.
  defp bool_result(result) do
    with {:ok, %Tesla.Env{body: body}} <- Error.normalize(result) do
      {:ok, parse_bool(body)}
    end
  end

  defp parse_bool(true), do: true
  defp parse_bool(false), do: false
  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(%{} = map), do: map |> Map.values() |> Enum.any?(&parse_bool/1)
  defp parse_bool(_), do: false

  # Raw-env bodies vary between a bare string, a JSON-encoded object, and a
  # decoded map — these endpoints are mapped {200, false}, so no JSON
  # middleware has touched the body.
  defp extract_string(body, key) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{} = map} -> extract_string(map, key)
      _ -> body
    end
  end

  defp extract_string(%{} = body, key) do
    Map.get(body, key) || body |> Map.values() |> List.first()
  end
end
