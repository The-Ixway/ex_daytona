defmodule ExDaytona.Webhooks do
  @moduledoc """
  Daytona webhooks: enabling them for an organization, and verifying the
  deliveries your endpoint receives.

  ## Setting up

  Daytona delivers webhooks through Svix. Initialize the org once, then
  configure endpoints and event subscriptions in the Svix app portal:

      {:ok, _status} = ExDaytona.Webhooks.initialize(client, org_id)
      {:ok, %{url: portal_url}} = ExDaytona.Webhooks.portal(client, org_id)
      # open portal_url in a browser to add endpoints / choose events

  ## Receiving

  Deliveries are signed (Svix / Standard Webhooks scheme). In your
  endpoint, verify with the endpoint's signing secret (`whsec_...`, from
  the portal) using the **raw request body** — any re-encoding breaks the
  signature:

      # e.g. in a Phoenix controller with a raw-body plug
      case ExDaytona.Webhooks.verify(raw_body, conn.req_headers, secret) do
        {:ok, event} -> handle(event["type"] || event, ...)
        {:error, %ExDaytona.Error{}} -> send_resp(conn, 400, "invalid signature")
      end

  `verify/4` checks the HMAC signature and the timestamp tolerance, then
  returns the decoded JSON payload.
  """

  alias ExDaytona.Api
  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model

  @default_tolerance_seconds 300

  ## Setup -------------------------------------------------------------------

  @doc """
  Enable webhooks for an organization (idempotent server-side). Returns
  the `ExDaytona.Model.WebhookInitializationStatus`.
  """
  @spec initialize(Client.t(), String.t()) ::
          {:ok, Model.WebhookInitializationStatus.t()} | {:error, Error.t()}
  def initialize(%Client{} = client, org_id) when is_binary(org_id) do
    Error.normalize(Api.Webhooks.initialize_webhooks(client.conn, org_id))
  end

  @doc """
  The organization's webhook initialization status.
  """
  @spec status(Client.t(), String.t()) ::
          {:ok, Model.WebhookInitializationStatus.t()} | {:error, Error.t()}
  def status(%Client{} = client, org_id) when is_binary(org_id) do
    Error.normalize(Api.Webhooks.get_initialization_status(client.conn, org_id))
  end

  @doc """
  A short-lived URL (and token) for the organization's Svix app portal,
  where endpoints and event subscriptions are managed. Returns
  `{:ok, %{url, token}}`.
  """
  @spec portal(Client.t(), String.t()) ::
          {:ok, %{url: String.t(), token: String.t() | nil}} | {:error, Error.t()}
  def portal(%Client{} = client, org_id) when is_binary(org_id) do
    with {:ok, %Model.WebhookAppPortalAccess{url: url, token: token}} <-
           Error.normalize(Api.Webhooks.get_app_portal_access(client.conn, org_id)) do
      {:ok, %{url: url, token: token}}
    end
  end

  @doc """
  Re-sync the organization's webhook endpoint configuration. Returns
  `:ok`.
  """
  @spec refresh_endpoints(Client.t(), String.t()) :: :ok | {:error, Error.t()}
  def refresh_endpoints(%Client{} = client, org_id) when is_binary(org_id) do
    with {:ok, _} <- Error.normalize(Api.Webhooks.refresh_endpoints(client.conn, org_id)) do
      :ok
    end
  end

  ## Receiving ---------------------------------------------------------------

  @doc """
  Verify a webhook delivery and return its decoded JSON payload.

  - `payload` — the **raw** request body, exactly as received
  - `headers` — the request headers (a map or a `[{name, value}]` list;
    names are matched case-insensitively). Svix's `svix-id`,
    `svix-timestamp`, `svix-signature` and the Standard Webhooks
    `webhook-*` aliases are both accepted.
  - `secret` — the endpoint's signing secret (`whsec_...`)

  ## Options

  - `:tolerance_seconds` — max allowed clock skew for the timestamp
    (default `#{@default_tolerance_seconds}`)
  - `:now` — unix seconds to validate against (defaults to the current
    time; useful in tests)
  """
  @spec verify(binary(), Enumerable.t(), String.t(), keyword()) ::
          {:ok, map() | list() | binary()} | {:error, Error.t()}
  def verify(payload, headers, secret, opts \\ []) when is_binary(payload) do
    headers = normalize_headers(headers)

    with {:ok, id} <- fetch_header(headers, "id"),
         {:ok, timestamp} <- fetch_header(headers, "timestamp"),
         {:ok, signature_header} <- fetch_header(headers, "signature"),
         :ok <- check_timestamp(timestamp, opts),
         {:ok, key} <- decode_secret(secret),
         :ok <- check_signature(key, id, timestamp, payload, signature_header) do
      case JSON.decode(payload) do
        {:ok, event} -> {:ok, event}
        {:error, _} -> {:ok, payload}
      end
    end
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {name, value} -> {String.downcase(to_string(name)), value} end)
  end

  defp fetch_header(headers, suffix) do
    case headers["svix-" <> suffix] || headers["webhook-" <> suffix] do
      nil -> {:error, %Error{message: "missing webhook header: svix-#{suffix}"}}
      value -> {:ok, value}
    end
  end

  defp check_timestamp(timestamp, opts) do
    tolerance = Keyword.get(opts, :tolerance_seconds, @default_tolerance_seconds)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

    case Integer.parse(timestamp) do
      {ts, ""} when abs(now - ts) <= tolerance ->
        :ok

      {_ts, ""} ->
        {:error, %Error{message: "webhook timestamp outside tolerance (#{tolerance}s)"}}

      _ ->
        {:error, %Error{message: "invalid webhook timestamp: #{inspect(timestamp)}"}}
    end
  end

  defp decode_secret("whsec_" <> encoded), do: decode_secret_b64(encoded)
  defp decode_secret(encoded) when is_binary(encoded), do: decode_secret_b64(encoded)

  defp decode_secret_b64(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, %Error{message: "invalid webhook secret: not base64"}}
    end
  end

  defp check_signature(key, id, timestamp, payload, signature_header) do
    expected = :crypto.mac(:hmac, :sha256, key, "#{id}.#{timestamp}.#{payload}")

    valid? =
      signature_header
      |> String.split(" ", trim: true)
      |> Enum.any?(fn versioned ->
        case String.split(versioned, ",", parts: 2) do
          ["v1", candidate] -> constant_time_equal?(candidate, Base.encode64(expected))
          _ -> false
        end
      end)

    if valid? do
      :ok
    else
      {:error, %Error{message: "webhook signature mismatch"}}
    end
  end

  defp constant_time_equal?(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp constant_time_equal?(_a, _b), do: false
end
