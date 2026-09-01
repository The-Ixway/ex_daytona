defmodule ExDaytona.Error do
  @moduledoc """
  Normalized error for the SDK facade.

  The generated openapi-generator client returns three different shapes for
  failures (spec-declared error models as `{:ok, error_struct}`, undeclared
  statuses as `{:error, %Tesla.Env{}}`, and transport failures as
  `{:error, reason}`). `normalize/1` collapses all of them into
  `{:error, %ExDaytona.Error{}}` so facade callers match one shape:

  - `status` — HTTP status, or `nil` for transport failures
  - `message` — human-readable message
  - `code` — the API's error code string, when it sent one
  - `details` — the raw error payload (decoded map, model struct, or
    transport reason) for anything the other fields don't capture

  Response metadata (populated when the failing call carried it — facade
  calls and generated calls made with `response: :full`):

  - `headers` — normalized response headers
  - `request_id` — provider request/correlation id
  - `rate_limit` — `%{limit, remaining, reset}` when the provider sent it
  - `retry_after` — parsed `Retry-After` seconds
  - `retry_count` — transport retries the SDK performed

  ## Outcome classification

  `outcome` distinguishes what the failure proves:

  - `:definite` — the provider answered; the request was rejected or
    completed with a known response
  - `:unknown` — the transport failed (timeout, connection loss) and a
    non-idempotent request MAY have been accepted before the failure.
    For idempotent requests an `:unknown` outcome is safe to retry; for
    POSTs the application must reconcile before retrying.
  """

  alias ExDaytona.Model.ErrorResponse
  alias ExDaytona.Response

  defstruct [
    :status,
    :message,
    :code,
    :details,
    :headers,
    :request_id,
    :rate_limit,
    :retry_after,
    :retry_count,
    outcome: :definite
  ]

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          message: String.t() | nil,
          code: String.t() | nil,
          details: term(),
          headers: [{binary(), binary()}] | nil,
          request_id: binary() | nil,
          rate_limit: Response.rate_limit() | nil,
          retry_after: non_neg_integer() | nil,
          retry_count: non_neg_integer() | nil,
          outcome: :definite | :unknown
        }

  @doc """
  Collapse a generated-client result into `{:ok, value}` or
  `{:error, %ExDaytona.Error{}}`.

  Success values (decoded models, lists, maps, and 2xx `Tesla.Env`
  passthroughs) are left untouched. Results from calls made with
  `response: :full` are unwrapped to their `data` on success and enriched
  with the response metadata on failure.
  """
  @spec normalize(term()) :: {:ok, term()} | {:error, t()}
  def normalize({:ok, %Response{data: %ErrorResponse{}} = response}),
    do: {:error, from(response)}

  def normalize({:ok, %Response{status: status} = response}) when status >= 400,
    do: {:error, from(response)}

  def normalize({:ok, %Response{data: data}}), do: {:ok, data}

  def normalize({:ok, %ErrorResponse{} = error}), do: {:error, from(error)}

  def normalize({:ok, %Tesla.Env{status: status} = env}) when status >= 400,
    do: {:error, from(env)}

  def normalize({:ok, value}), do: {:ok, value}

  # A 2xx the spec didn't declare: the generated client can only return it
  # as {:error, env}, but the server succeeded — the spec is just behind
  # (e.g. a 201 where the spec declares 200). Treat it as success.
  def normalize({:error, %Tesla.Env{status: status} = env}) when status in 200..299,
    do: {:ok, env}

  def normalize({:error, reason}), do: {:error, from(reason)}

  @doc """
  Like `normalize/1`, but keeps the full `%ExDaytona.Response{}` envelope
  on success instead of unwrapping to `data`.
  """
  @spec normalize_full(term()) :: {:ok, Response.t()} | {:error, t()}
  def normalize_full({:ok, %Response{}} = result) do
    case normalize(result) do
      {:ok, _data} -> result
      {:error, _} = error -> error
    end
  end

  def normalize_full(other), do: normalize(other)

  @doc """
  Build an `ExDaytona.Error` from any failure shape the generated client
  produces.
  """
  @spec from(term()) :: t()
  def from(%__MODULE__{} = error), do: error

  def from(%Response{data: %ErrorResponse{} = model} = response) do
    %{from(model) | status: from(model).status || response.status}
    |> put_metadata(response)
  end

  def from(%Response{data: %Tesla.Env{} = env} = response) do
    env |> from() |> put_metadata(response)
  end

  def from(%Response{data: data} = response) do
    %__MODULE__{
      status: response.status,
      message: message_from_body(data) || "HTTP #{response.status}",
      code: code_from_body(data),
      details: data
    }
    |> put_metadata(response)
  end

  def from(%ErrorResponse{} = error) do
    %__MODULE__{
      status: error.statusCode,
      message: error.message,
      code: error.code,
      details: error
    }
  end

  def from(%Tesla.Env{status: status, body: body} = env) do
    headers = Response.normalize_headers(env.headers)

    %__MODULE__{
      status: status,
      message: message_from_body(body) || "HTTP #{status}",
      code: code_from_body(body),
      details: body,
      headers: headers,
      request_id: Response.get_header(headers, "x-request-id"),
      rate_limit: Response.parse_rate_limit(headers),
      retry_after: Response.parse_retry_after(Response.get_header(headers, "retry-after")),
      retry_count: env.opts[:ex_daytona_retry_count]
    }
  end

  # Transport-level failure: no response was observed, so a non-idempotent
  # request may have been accepted before the failure — the outcome cannot
  # honestly be called definite.
  def from(reason) do
    %__MODULE__{message: transport_message(reason), details: reason, outcome: :unknown}
  end

  defp put_metadata(%__MODULE__{} = error, %Response{} = response) do
    %{
      error
      | headers: response.headers,
        request_id: response.request_id,
        rate_limit: response.rate_limit,
        retry_after: response.retry_after,
        retry_count: response.retry_count
    }
  end

  defp message_from_body(%{"message" => message}) when is_binary(message), do: message
  defp message_from_body(%{"error" => error}) when is_binary(error), do: error
  defp message_from_body(body) when is_binary(body) and body != "", do: body
  defp message_from_body(_), do: nil

  defp code_from_body(%{"code" => code}) when is_binary(code), do: code
  defp code_from_body(%{"error" => error, "message" => _}) when is_binary(error), do: error
  defp code_from_body(_), do: nil

  defp transport_message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp transport_message(reason), do: "transport error: #{inspect(reason)}"
end
