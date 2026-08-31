defmodule ExDaytona.HTTPStream do
  @moduledoc false
  # Internal: incrementally consumes chunked HTTP responses (log following)
  # via Finch. The Tesla Finch adapter buffers entire responses, so
  # streaming endpoints bypass Tesla and use the SDK's Finch pool directly.

  alias ExDaytona.Error

  @doc """
  GET `url` and invoke `fun` with each body chunk as it arrives.

  Returns `:ok` when the stream ends, `{:error, %ExDaytona.Error{}}` on a
  non-2xx status (body collected into the error) or transport failure.

  Options: `:timeout` — max milliseconds to wait for each chunk
  (default `:infinity`, since a followed log stream can be idle).
  """
  @spec get(String.t(), String.t(), (binary() -> any()), keyword()) ::
          :ok | {:error, Error.t()}
  def get(url, api_key, fun, opts \\ []) when is_function(fun, 1) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    request =
      Finch.build(:get, url, [
        {"authorization", "Bearer " <> api_key},
        {"accept", "application/octet-stream, text/plain, */*"}
      ])

    handle_chunk = fn
      {:status, status}, {_status, error_body} ->
        {status, error_body}

      {:headers, _headers}, acc ->
        acc

      {:data, chunk}, {status, error_body} when status >= 400 ->
        {status, [error_body, chunk]}

      {:data, chunk}, acc ->
        fun.(chunk)
        acc
    end

    case Finch.stream(request, ExDaytona.Finch, {nil, []}, handle_chunk, receive_timeout: timeout) do
      {:ok, {status, _}} when status < 400 ->
        :ok

      {:ok, {status, error_body}} ->
        body = error_body |> IO.iodata_to_binary() |> decode_error_body()
        {:error, Error.from(%Tesla.Env{status: status, body: body})}

      {:error, reason, _acc} ->
        {:error, Error.from(reason)}
    end
  end

  defp decode_error_body(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end
end
