defmodule ExDaytona.HTTPStream do
  @moduledoc false
  # Internal: incrementally consumes chunked HTTP responses (log following)
  # through the configured `ExDaytona.Transport.HTTPStream` implementation.
  # Runs on the dedicated stream pool by default so long-lived follows
  # cannot starve lifecycle/control requests.

  alias ExDaytona.Error

  # Non-2xx responses collect their body into the error — bounded, so a
  # misbehaving server cannot balloon memory through an error response.
  @max_error_body_bytes 65_536

  @doc """
  GET `url` and invoke `fun` with each body chunk as it arrives.

  Returns `:ok` when the stream ends, `{:error, %ExDaytona.Error{}}` on a
  non-2xx status (body collected, bounded) or transport failure.

  Options:

  - `:timeout` — max milliseconds to wait between chunks (idle timeout;
    default `:infinity`, since a followed log stream can be idle)
  - `:deadline` — overall milliseconds for the whole stream (default
    `:infinity`); enforced even while chunks keep arriving
  - `:transport` — `ExDaytona.Transport.HTTPStream` implementation
    (default `ExDaytona.Transport.FinchStream`)
  - `:pool` — passed through to the transport
  """
  @spec get(String.t(), String.t(), (binary() -> any()), keyword()) ::
          :ok | {:error, Error.t()}
  def get(url, api_key, fun, opts \\ []) when is_function(fun, 1) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    deadline = deadline_at(Keyword.get(opts, :deadline, :infinity))
    transport = Keyword.get(opts, :transport, ExDaytona.Transport.FinchStream)

    headers = [
      {"authorization", "Bearer " <> api_key},
      {"accept", "application/octet-stream, text/plain, */*"}
    ]

    handle = fn
      {:status, status}, {_status, error_body, deadline_hit?} ->
        {:cont, {status, error_body, deadline_hit?}}

      {:headers, _headers}, acc ->
        {:cont, acc}

      {:data, chunk}, {status, error_body, _} = acc ->
        cond do
          past?(deadline) ->
            {:halt, {status, error_body, true}}

          status >= 400 ->
            {:cont, {status, bounded_append(error_body, chunk), false}}

          true ->
            fun.(chunk)
            {:cont, acc}
        end
    end

    transport_opts = [receive_timeout: timeout] ++ Keyword.take(opts, [:pool])

    case transport.stream("GET", url, headers, nil, {nil, [], false}, handle, transport_opts) do
      {:ok, {_status, _body, true}} ->
        {:error, %Error{message: "stream exceeded its overall deadline"}}

      {:ok, {status, _body, _}} when status < 400 ->
        :ok

      {:ok, {status, error_body, _}} ->
        body = error_body |> IO.iodata_to_binary() |> decode_error_body()
        {:error, Error.from(%Tesla.Env{status: status, body: body})}

      {:error, reason, _acc} ->
        {:error, Error.from(reason)}
    end
  end

  @doc false
  def deadline_at(:infinity), do: :infinity
  def deadline_at(ms) when is_integer(ms), do: System.monotonic_time(:millisecond) + ms

  @doc false
  def past?(:infinity), do: false
  def past?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp bounded_append(iodata, chunk) do
    if IO.iodata_length(iodata) >= @max_error_body_bytes do
      iodata
    else
      [iodata, chunk]
    end
  end

  defp decode_error_body(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end
end
