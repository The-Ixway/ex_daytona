defmodule ExDaytona.Testing.Resolution do
  @moduledoc false
  # Which processes' scripts apply to the current process: itself, then the
  # caller chain (Task and the SDK's internal producers propagate
  # `$callers`), then the OTP ancestor chain (GenServers like
  # ExDaytona.LogStream started from a test resolve the test's script).
  def candidates do
    [self() | List.wrap(Process.get(:"$callers")) ++ List.wrap(Process.get(:"$ancestors"))]
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end
end

defmodule ExDaytona.Testing.HTTPStream do
  @moduledoc false
  # Scripted ExDaytona.Transport.HTTPStream double (see
  # ExDaytona.Testing.script_http_stream/1).

  @behaviour ExDaytona.Transport.HTTPStream

  alias ExDaytona.Testing.Resolution
  alias ExDaytona.Testing.Server

  @impl true
  def stream(_method, _url, _headers, body, acc, fun, _opts) do
    script = Server.get_script(Resolution.candidates(), :http_stream) || %{}

    consume_request_body(body, script)

    status = Map.get(script, :status, 200)
    chunks = Map.get(script, :chunks, [])
    chunk_delay = Map.get(script, :chunk_delay, 0)

    with {:cont, acc} <- fun.({:status, status}, acc),
         {:cont, acc} <- fun.({:headers, Map.get(script, :headers, [])}, acc) do
      deliver(chunks, chunk_delay, acc, fun, script)
    else
      {:halt, acc} -> {:ok, acc}
    end
  end

  defp deliver([], _delay, acc, _fun, script) do
    case Map.get(script, :error) do
      nil -> {:ok, acc}
      reason -> {:error, reason, acc}
    end
  end

  defp deliver([chunk | rest], delay, acc, fun, script) do
    if delay > 0, do: Process.sleep(delay)

    case fun.({:data, chunk}, acc) do
      {:cont, acc} -> deliver(rest, delay, acc, fun, script)
      {:halt, acc} -> {:ok, acc}
    end
  end

  # Uploads send a lazy {:stream, enum} request body — consume it so the
  # SDK's progress/abort/sha machinery runs as it would against a real
  # server.
  defp consume_request_body({:stream, enum}, script) do
    pulled =
      case Map.get(script, :consume_request_chunks, :all) do
        :all -> Enum.count(enum)
        n -> enum |> Stream.take(n) |> Enum.count()
      end

    Process.put(:ex_daytona_testing_request_chunks_pulled, pulled)
    :ok
  end

  defp consume_request_body(_other, _script), do: :ok
end

defmodule ExDaytona.Testing.WebSocket do
  @moduledoc false
  # Scripted ExDaytona.Transport.WebSocketClient double (see
  # ExDaytona.Testing.script_ws/1): replays frames to the owner using the
  # SDK's websocket message protocol.

  @behaviour ExDaytona.Transport.WebSocketClient

  alias ExDaytona.Testing.Resolution
  alias ExDaytona.Testing.Server

  @impl true
  def connect(_url, _api_key, opts) do
    script = Server.get_script(Resolution.candidates(), :ws) || %{}

    case Map.get(script, :connect) do
      {:error, _} = error ->
        error

      _ok ->
        owner = Keyword.get(opts, :owner, self())
        {:ok, spawn(fn -> replay(owner, script) end)}
    end
  end

  defp replay(owner, script) do
    frame_delay = Map.get(script, :frame_delay, 0)

    Enum.each(Map.get(script, :frames, []), fn frame ->
      if frame_delay > 0, do: Process.sleep(frame_delay)
      send(owner, {:ex_daytona_ws, self(), frame})
    end)

    unless Map.get(script, :hold_open, false) do
      send(owner, {:ex_daytona_ws, self(), {:closed, Map.get(script, :close_reason, :normal)}})
    end

    receive do
      :close -> send(owner, {:ex_daytona_ws, self(), {:closed, :normal}})
    end
  end

  @impl true
  def send_text(pid, data) do
    send(pid, {:ex_daytona_testing_ws_sent, :text, IO.iodata_to_binary(data)})
    :ok
  end

  @impl true
  def send_binary(pid, data) do
    send(pid, {:ex_daytona_testing_ws_sent, :binary, IO.iodata_to_binary(data)})
    :ok
  end

  @impl true
  def close(pid) do
    send(pid, :close)
    :ok
  end
end
