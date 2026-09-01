defmodule ExDaytona.Testing.Adapter do
  @moduledoc false
  # Tesla adapter for ExDaytona.Testing clients: answers every request from
  # the owner's scripted expectations/stubs instead of the network. The
  # owner is baked into the adapter opts when the client is built, so
  # requests made from spawned processes still resolve the right script.

  @behaviour Tesla.Adapter

  alias ExDaytona.Testing.Server

  @impl Tesla.Adapter
  def call(env, opts) do
    owner = Keyword.fetch!(opts, :owner)
    path = URI.parse(env.url).path || "/"
    method = env.method |> Atom.to_string() |> String.upcase()

    case Server.checkout([owner], method, path) do
      {:ok, response} ->
        apply_response(env, response)

      {:error, {:unexpected, remaining}} ->
        raise ExDaytona.Testing.UnexpectedRequestError,
              unexpected_message(method, path, remaining)
    end
  end

  defp apply_response(env, fun) when is_function(fun, 1), do: apply_response(env, fun.(env))

  defp apply_response(_env, {:error, reason}), do: {:error, reason}

  defp apply_response(env, %Tesla.Env{status: status, body: body, headers: headers}) do
    {:ok, %{env | status: status, body: body, headers: headers}}
  end

  defp apply_response(env, status) when is_integer(status) do
    {:ok, %{env | status: status, body: "", headers: []}}
  end

  defp apply_response(env, {status, body}) when is_integer(status) do
    {body, headers} = encode_body(body)
    {:ok, %{env | status: status, body: body, headers: headers}}
  end

  defp apply_response(env, response) when is_list(response) do
    if explicit_keyword?(response) do
      {body, headers} = response |> Keyword.get(:body, "") |> encode_body()

      {:ok,
       %{
         env
         | status: Keyword.get(response, :status, 200),
           body: body,
           headers: Keyword.get(response, :headers, headers)
       }}
    else
      apply_response(env, {200, response})
    end
  end

  defp apply_response(env, response) when is_map(response) or is_binary(response) do
    apply_response(env, {200, response})
  end

  defp explicit_keyword?(response) do
    Keyword.keyword?(response) and
      Enum.any?([:status, :body, :headers], &Keyword.has_key?(response, &1))
  end

  defp encode_body(body) when is_binary(body), do: {body, [{"content-type", "text/plain"}]}

  defp encode_body(body) when is_map(body) or is_list(body),
    do: {JSON.encode!(body), [{"content-type", "application/json"}]}

  defp encode_body(nil), do: {"", []}

  defp unexpected_message(method, path, remaining) do
    header = "unexpected request: #{method} #{path}"

    case remaining do
      [] ->
        header <>
          " — no expectations or stubs matched (set them up with " <>
          "ExDaytona.Testing.expect/3 or stub/3 in the test process that built the client)"

      expectations ->
        listed = Enum.map_join(expectations, "\n  ", &"#{&1.method} #{&1.path}")
        header <> " — remaining expectations:\n  " <> listed
    end
  end
end
