defmodule ExDaytona.Response do
  @moduledoc """
  Full response envelope for generated operations.

  By default generated calls return just the decoded value
  (`{:ok, model}`). Passing `response: :full` in an operation's `opts`
  returns `{:ok, %ExDaytona.Response{}}` instead, preserving the response
  metadata that is otherwise discarded:

      {:ok, %ExDaytona.Response{data: sandbox, request_id: id, rate_limit: rl}} =
        ExDaytona.Api.Sandbox.get_sandbox(conn, "sb-1", response: :full)

  - `data` — the decoded value the default mode would have returned
  - `status` — HTTP status
  - `headers` — response headers, names lower-cased, order preserved
  - `request_id` — the provider's request/correlation id, when sent
  - `rate_limit` — `%{limit, remaining, reset}` (integers, `nil` when the
    provider omitted a part)
  - `retry_after` — parsed `Retry-After` in seconds (integer and
    HTTP-date forms), when present
  - `retry_count` — transport-level retries the SDK performed for this
    call (0 when it succeeded first try)

  Declared error models are wrapped the same way, so error metadata is
  never lost. The facade's `ExDaytona.Error` carries the same fields.
  """

  defstruct [
    :status,
    :data,
    :headers,
    :request_id,
    :rate_limit,
    :retry_after,
    :retry_count
  ]

  @type rate_limit :: %{
          limit: non_neg_integer() | nil,
          remaining: non_neg_integer() | nil,
          reset: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          data: term(),
          headers: [{binary(), binary()}],
          request_id: binary() | nil,
          rate_limit: rate_limit() | nil,
          retry_after: non_neg_integer() | nil,
          retry_count: non_neg_integer()
        }

  @request_id_headers ~w(x-request-id x-correlation-id x-amzn-requestid request-id)
  @rate_limit_prefixes ~w(x-ratelimit- x-rate-limit- ratelimit-)

  @doc """
  Build a response envelope from a `Tesla.Env` and the decoded data.
  """
  @spec from_env(Tesla.Env.t(), term()) :: t()
  def from_env(%Tesla.Env{} = env, data) do
    headers = normalize_headers(env.headers)

    %__MODULE__{
      status: env.status,
      data: data,
      headers: headers,
      request_id: first_header(headers, @request_id_headers),
      rate_limit: parse_rate_limit(headers),
      retry_after: parse_retry_after(get_header(headers, "retry-after")),
      retry_count: env.opts[:ex_daytona_retry_count] || 0
    }
  end

  @doc """
  The first value of `name` (case-insensitive) from a header list or a
  `%ExDaytona.Response{}`.
  """
  @spec get_header(t() | [{binary(), binary()}], binary()) :: binary() | nil
  def get_header(%__MODULE__{headers: headers}, name), do: get_header(headers, name)

  def get_header(headers, name) when is_list(headers) do
    down = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == down, do: value
    end)
  end

  @doc """
  All values of `name` (case-insensitive).
  """
  @spec get_headers(t() | [{binary(), binary()}], binary()) :: [binary()]
  def get_headers(%__MODULE__{headers: headers}, name), do: get_headers(headers, name)

  def get_headers(headers, name) when is_list(headers) do
    down = String.downcase(name)
    for {key, value} <- headers, String.downcase(key) == down, do: value
  end

  @doc """
  Lower-case header names, preserving order and unknown headers.
  """
  @spec normalize_headers([{binary(), binary()}] | nil) :: [{binary(), binary()}]
  def normalize_headers(nil), do: []

  def normalize_headers(headers) do
    Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)
  end

  @doc """
  Parse a `Retry-After` header value: integer seconds, or an HTTP-date
  (delta from now, floored at 0). Returns `nil` for absent/invalid
  values.
  """
  @spec parse_retry_after(binary() | nil) :: non_neg_integer() | nil
  def parse_retry_after(nil), do: nil

  def parse_retry_after(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 ->
        seconds

      _ ->
        case parse_http_date(value) do
          nil -> nil
          unix -> max(unix - System.system_time(:second), 0)
        end
    end
  end

  @doc false
  # RFC 7231 IMF-fixdate, e.g. "Wed, 21 Oct 2015 07:28:00 GMT"
  def parse_http_date(value) do
    with [_day_name, day, month_name, year, time, "GMT"] <-
           value |> String.trim() |> String.split(" ", trim: true),
         {day, ""} <- Integer.parse(day),
         month when month != nil <- month_number(month_name),
         {year, ""} <- Integer.parse(year),
         [hour, minute, second] <- String.split(time, ":"),
         {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         {second, ""} <- Integer.parse(second),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      DateTime.to_unix(datetime)
    else
      _ -> nil
    end
  end

  defp month_number(name) do
    %{
      "Jan" => 1,
      "Feb" => 2,
      "Mar" => 3,
      "Apr" => 4,
      "May" => 5,
      "Jun" => 6,
      "Jul" => 7,
      "Aug" => 8,
      "Sep" => 9,
      "Oct" => 10,
      "Nov" => 11,
      "Dec" => 12
    }[name]
  end

  defp first_header(headers, names) do
    Enum.find_value(names, &get_header(headers, &1))
  end

  @doc false
  def parse_rate_limit(headers) do
    limit = rate_limit_value(headers, "limit")
    remaining = rate_limit_value(headers, "remaining")
    reset = rate_limit_value(headers, "reset")

    if limit || remaining || reset do
      %{limit: limit, remaining: remaining, reset: reset}
    end
  end

  defp rate_limit_value(headers, suffix) do
    Enum.find_value(@rate_limit_prefixes, fn prefix ->
      headers |> get_header(prefix <> suffix) |> parse_int()
    end)
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} -> int
      :error -> nil
    end
  end
end
