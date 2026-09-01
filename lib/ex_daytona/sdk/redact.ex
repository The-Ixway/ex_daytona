defmodule ExDaytona.Redact do
  @moduledoc """
  Credential redaction for inspection and diagnostics.

  Every generated model, plus the credential-bearing facade structs
  (`ExDaytona.Client`, `ExDaytona.Error`, SSH/preview/storage results),
  renders through here for `inspect/1` — fields whose names indicate
  credentials come out as `"[REDACTED]"` while nonsecret fields stay
  visible for debugging. `deep/1` sanitizes arbitrary nested values (for
  error details and logging).

  A field is considered sensitive when its name contains any of:
  `api_key`/`apikey`, `authorization`, `token`, `secret`, `password`,
  `credential`, `access_key`/`accesskey`. Matching is case-insensitive
  and underscore-insensitive, so camelCase model fields
  (`sessionToken`, `accessKey`) are covered. `value` fields on
  secret-typed models (`CreateSecret`, `UpdateSecret`, resolved secret
  bindings) are also redacted.

  Note: this intentionally over-redacts some non-credentials (e.g.
  pagination `nextToken` cursors) — a safe default.
  """

  import Inspect.Algebra

  @marker "[REDACTED]"

  @sensitive_fragments ~w(apikey authorization token secret password credential accesskey)

  # URL query parameters that carry signatures/credentials
  @sensitive_query_params ~w(token signature sig x-amz-security-token x-amz-signature apikey api_key access_key)

  @doc "The stable replacement marker."
  def marker, do: @marker

  @doc """
  Whether a field name indicates a credential.
  """
  @spec sensitive_key?(atom() | binary()) :: boolean()
  def sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))

  def sensitive_key?(key) when is_binary(key) do
    normalized = key |> String.downcase() |> String.replace(["_", "-"], "")
    Enum.any?(@sensitive_fragments, &String.contains?(normalized, &1))
  end

  def sensitive_key?(_), do: false

  @doc """
  Deep-sanitize a value: maps and keyword/tuple lists have sensitive keys'
  values replaced (string keys matched case-insensitively), recursively.
  Structs are converted to sanitized maps tagged with their module.
  """
  @spec deep(term()) :: term()
  def deep(%_{} = struct) do
    struct |> Map.from_struct() |> deep() |> Map.put(:__struct__, struct.__struct__)
  end

  def deep(%{} = map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key), do: {key, @marker}, else: {key, deep(value)}
    end)
  end

  def deep(list) when is_list(list) do
    Enum.map(list, fn
      {key, value} when is_atom(key) or is_binary(key) ->
        if sensitive_key?(key), do: {key, @marker}, else: {key, deep(value)}

      other ->
        deep(other)
    end)
  end

  def deep(other), do: other

  @doc """
  Scrub signed/credential query parameters from URLs embedded in a
  message string.
  """
  @spec scrub_message(binary() | nil) :: binary() | nil
  def scrub_message(nil), do: nil

  def scrub_message(message) when is_binary(message) do
    Regex.replace(~r/https?:\/\/[^\s"']+/, message, fn url -> scrub_url(url) end)
  end

  @doc false
  def scrub_url(url) do
    case String.split(url, "?", parts: 2) do
      [_base] ->
        url

      [base, query] ->
        scrubbed =
          query
          |> String.split("&")
          |> Enum.map_join("&", &scrub_query_pair/1)

        base <> "?" <> scrubbed
    end
  end

  defp scrub_query_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, _value] ->
        if String.downcase(key) in @sensitive_query_params,
          do: key <> "=" <> @marker,
          else: pair

      _ ->
        pair
    end
  end

  @doc """
  Inspect implementation body for structs: renders like the default
  struct inspect but with sensitive fields redacted. Used by every
  generated model's `Inspect` impl and the facade's credential-bearing
  structs.

  `extra_sensitive` names additional fields to redact regardless of
  their name (e.g. `:value` on secret models).
  """
  @spec inspect_struct(struct(), Inspect.Opts.t(), [atom()]) :: Inspect.Algebra.t()
  def inspect_struct(struct, opts, extra_sensitive \\ []) do
    module = struct.__struct__

    entries =
      struct
      |> Map.from_struct()
      |> Enum.map(fn {key, value} ->
        if sensitive?(module, key, value, extra_sensitive) do
          {key, @marker}
        else
          {key, value}
        end
      end)

    container_doc(
      "#" <> Kernel.inspect(module) <> "<",
      entries,
      ">",
      opts,
      fn {key, value}, opts ->
        concat([Atom.to_string(key), ": ", to_doc(value, opts)])
      end,
      separator: ","
    )
  end

  defp sensitive?(_module, _key, nil, _extra), do: false

  defp sensitive?(module, key, _value, extra) do
    sensitive_key?(key) or key in extra or (secret_model?(module) and key == :value)
  end

  defp secret_model?(module) do
    name = module |> Kernel.inspect() |> String.downcase()

    String.contains?(name, "secret") or String.contains?(name, "credential") or
      String.contains?(name, "apikey")
  end
end
