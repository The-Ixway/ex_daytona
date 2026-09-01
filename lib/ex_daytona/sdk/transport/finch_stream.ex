defmodule ExDaytona.Transport.FinchStream do
  @moduledoc """
  The default `ExDaytona.Transport.HTTPStream` implementation, built on
  `Finch.stream_while/5`.

  Long-lived and bulk streams run on the SDK's dedicated stream pool
  (`ExDaytona.Finch.Stream`) by default, so active log follows and large
  file transfers cannot starve the main pool used by lifecycle/control
  requests. Pass `pool: ExDaytona.Finch` to opt a call onto the main pool.
  """

  @behaviour ExDaytona.Transport.HTTPStream

  @default_pool ExDaytona.Finch.Stream

  @impl true
  def stream(method, url, headers, body, acc, fun, opts \\ []) do
    receive_timeout = Keyword.get(opts, :receive_timeout, 120_000)
    pool = Keyword.get(opts, :pool, @default_pool)

    request = Finch.build(method, url, headers, finch_body(body))

    case Finch.stream_while(request, pool, acc, fun, receive_timeout: receive_timeout) do
      {:ok, acc} -> {:ok, acc}
      {:error, reason, acc} -> {:error, reason, acc}
    end
  end

  defp finch_body(nil), do: nil
  defp finch_body({:stream, enumerable}), do: {:stream, enumerable}
  defp finch_body(iodata), do: IO.iodata_to_binary(iodata)
end
