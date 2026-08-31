defmodule ExDaytona.SigV4 do
  @moduledoc false
  # Minimal AWS Signature Version 4 signer for the S3-compatible object
  # storage used by declarative build contexts. Hand-rolled on :crypto so
  # the SDK needs no AWS dependency; correctness is pinned by AWS's
  # published SigV4 test vectors in the unit tests.

  @algorithm "AWS4-HMAC-SHA256"

  @doc """
  Sign an HTTP request. Returns the headers to send (including
  `authorization`, `x-amz-date`, `x-amz-content-sha256`, and
  `x-amz-security-token` when a session token is present).

  `creds` is a map with `:access_key`, `:secret`, `:region`, optional
  `:session_token`, and optional `:service` (default `"s3"`).
  `now` is a `DateTime` (injectable for tests).
  """
  @spec sign(String.t(), URI.t(), binary(), map(), DateTime.t()) :: [{String.t(), String.t()}]
  def sign(method, %URI{} = uri, body, creds, now) do
    service = Map.get(creds, :service, "s3")
    amz_date = format_amz_date(now)
    date_stamp = String.slice(amz_date, 0, 8)
    payload_hash = hex(:crypto.hash(:sha256, body))

    host =
      case uri.port do
        port when port in [80, 443, nil] -> uri.host
        port -> "#{uri.host}:#{port}"
      end

    base_headers =
      [
        {"host", host},
        {"x-amz-content-sha256", payload_hash},
        {"x-amz-date", amz_date}
      ] ++
        case Map.get(creds, :session_token) do
          nil -> []
          token -> [{"x-amz-security-token", token}]
        end

    sorted = Enum.sort_by(base_headers, &elem(&1, 0))
    signed_header_names = Enum.map_join(sorted, ";", &elem(&1, 0))

    canonical_headers =
      Enum.map_join(sorted, "", fn {name, value} -> "#{name}:#{String.trim(value)}\n" end)

    canonical_request =
      Enum.join(
        [
          method,
          canonical_path(uri),
          canonical_query(uri),
          canonical_headers,
          signed_header_names,
          payload_hash
        ],
        "\n"
      )

    credential_scope = "#{date_stamp}/#{creds.region}/#{service}/aws4_request"

    string_to_sign =
      Enum.join(
        [
          @algorithm,
          amz_date,
          credential_scope,
          hex(:crypto.hash(:sha256, canonical_request))
        ],
        "\n"
      )

    signing_key =
      ("AWS4" <> creds.secret)
      |> hmac(date_stamp)
      |> hmac(creds.region)
      |> hmac(service)
      |> hmac("aws4_request")

    signature = hex(hmac(signing_key, string_to_sign))

    authorization =
      "#{@algorithm} Credential=#{creds.access_key}/#{credential_scope}, " <>
        "SignedHeaders=#{signed_header_names}, Signature=#{signature}"

    [{"authorization", authorization} | base_headers]
  end

  defp canonical_path(%URI{path: path}) when path in [nil, ""], do: "/"

  # Each path segment URI-encoded (S3-style: '/' kept, everything else
  # percent-encoded per RFC 3986 unreserved).
  defp canonical_path(%URI{path: path}) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &uri_encode/1)
  end

  defp canonical_query(%URI{query: nil}), do: ""

  defp canonical_query(%URI{query: query}) do
    query
    |> URI.decode_query()
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> uri_encode(k) <> "=" <> uri_encode(v) end)
  end

  defp uri_encode(value) do
    URI.encode(value, fn char ->
      char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char in [?-, ?_, ?., ?~]
    end)
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp hex(binary), do: Base.encode16(binary, case: :lower)

  defp format_amz_date(%DateTime{} = now) do
    now
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
