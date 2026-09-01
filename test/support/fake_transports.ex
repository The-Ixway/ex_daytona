defmodule FakeTransports do
  @moduledoc """
  Deterministic transport doubles for stream-failure simulation.

  `FakeTransports.HTTPStream` replays a script of response events set up
  with `script_http/1` (per-process via the process dictionary, so
  async tests don't interfere):

      FakeTransports.script_http(
        status: 200,
        chunks: ["a", "b"],
        chunk_delay: 0,
        error: nil
      )

  `FakeTransports.WS` implements `ExDaytona.Transport.WebSocketClient` by
  spawning a process that replays scripted frames set with `script_ws/1`.
  """

  @table :fake_transport_scripts

  @doc "Configure the next HTTPStream call in this process."
  def script_http(opts), do: Process.put(:fake_http_script, Map.new(opts))

  @doc """
  Configure the next WS connect scripted by this process (or any process
  it starts — resolution walks `$ancestors`, so a GenServer like
  `ExDaytona.LogStream` started from the test finds the test's script).
  """
  def script_ws(opts) do
    ensure_table()
    :ets.insert(@table, {self(), Map.new(opts)})
    :ok
  end

  @doc false
  def lookup_ws_script do
    ensure_table()

    candidates = [self() | Process.get(:"$ancestors", [])]

    Enum.find_value(candidates, %{}, fn
      pid when is_pid(pid) ->
        case :ets.lookup(@table, pid) do
          [{_pid, script}] -> script
          [] -> nil
        end

      _named ->
        nil
    end)
  end

  defp ensure_table do
    :ets.new(@table, [:named_table, :public, :set])
  rescue
    ArgumentError -> @table
  end

  defmodule HTTPStream do
    @moduledoc false
    @behaviour ExDaytona.Transport.HTTPStream

    @impl true
    def stream(_method, _url, _headers, body, acc, fun, _opts) do
      script = Process.get(:fake_http_script) || %{}

      # Consume a lazy request body if the caller sent one, recording how
      # many elements were pulled (for laziness assertions).
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

    defp consume_request_body({:stream, enum}, script) do
      max_pull = Map.get(script, :consume_request_chunks, :all)

      pulled =
        case max_pull do
          :all -> Enum.count(enum)
          n -> enum |> Stream.take(n) |> Enum.count()
        end

      Process.put(:fake_http_request_chunks_pulled, pulled)
    end

    defp consume_request_body(_other, _script), do: :ok
  end

  defmodule WS do
    @moduledoc false
    @behaviour ExDaytona.Transport.WebSocketClient

    @impl true
    def connect(_url, _api_key, opts) do
      script = FakeTransports.lookup_ws_script()

      case Map.get(script, :connect) do
        {:error, _} = error ->
          error

        _ ->
          owner = Keyword.get(opts, :owner, self())
          frames = Map.get(script, :frames, [])
          frame_delay = Map.get(script, :frame_delay, 0)
          close_reason = Map.get(script, :close_reason, :normal)
          hold_open = Map.get(script, :hold_open, false)

          {:ok, spawn(fn -> replay(owner, frames, frame_delay, close_reason, hold_open) end)}
      end
    end

    defp replay(owner, frames, frame_delay, close_reason, hold_open) do
      Enum.each(frames, fn frame ->
        if frame_delay > 0, do: Process.sleep(frame_delay)
        send(owner, {:ex_daytona_ws, self(), frame})
      end)

      unless hold_open do
        send(owner, {:ex_daytona_ws, self(), {:closed, close_reason}})
      end

      receive do
        :close -> send(owner, {:ex_daytona_ws, self(), {:closed, :normal}})
      end
    end

    @impl true
    def send_text(pid, data) do
      send(pid, {:sent_text, data})
      :ok
    end

    @impl true
    def send_binary(pid, data) do
      send(pid, {:sent_binary, data})
      :ok
    end

    @impl true
    def close(pid) do
      send(pid, :close)
      :ok
    end
  end
end
