defmodule ExDaytona.LogStream do
  @moduledoc """
  Owned, bounded, structured streaming of session command logs.

  Where `ExDaytona.Session.stream_logs/4` delivers merged raw chunks over
  HTTP, a `LogStream` speaks the websocket protocol Daytona multiplexes
  command output on, and demultiplexes it back into separate `:stdout`
  and `:stderr` events in provider arrival order.

  > #### Channel separation depends on the daemon {: .warning}
  >
  > Separation requires the daemon to emit the channel-marker protocol.
  > Daemons that stream unlabeled output (the production daemon at the
  > time of this release — verified live) yield `{:output, bytes}`
  > events carrying the merged stream instead; consumers should handle
  > all three event shapes.

      {:ok, stream} =
        ExDaytona.Session.open_log_stream(session, cmd_id,
          max_buffer_bytes: 1_048_576,
          idle_timeout: 60_000
        )

      case ExDaytona.LogStream.next(stream, 5_000) do
        {:ok, {:stdout, bytes}} -> IO.write(bytes)
        {:ok, {:stderr, bytes}} -> IO.write(:stderr, bytes)
        {:closed, :normal} -> :done
        {:closed, {:error, %ExDaytona.Error{}}} -> :failed
      end

      :ok = ExDaytona.LogStream.close(stream)

  ## Contract

  - **Pull-based**: events are buffered inside the stream process and
    handed out one `next/2` at a time — no unbounded delivery into an
    ordinary mailbox, and nothing the consumer does can block the socket
    receive loop.
  - **Owned**: the stream monitors its owner (default: the opener) and
    shuts the connection down when the owner dies. `close/1` is
    idempotent.
  - **Bounded**: `max_buffer_bytes`/`max_frames` cap undelivered output
    and `max_frame_bytes` caps a single websocket frame; exceeding a
    bound closes the connection with an explicit overflow error.
  - **Deadlines**: `idle_timeout` (between frames) and `overall_timeout`
    (whole stream) close the stream with an explicit error.
  - **No hidden recovery**: a dropped connection is reported as closed;
    the stream never silently reconnects or replays (the provider offers
    no cursor to resume from).

  The final exit status is *not* part of the stream — after
  `{:closed, :normal}` use `ExDaytona.Session.command/2` or `await/3`.
  """

  use GenServer

  alias ExDaytona.Error

  @stdout_prefix <<0x01, 0x01, 0x01>>
  @stderr_prefix <<0x02, 0x02, 0x02>>
  @max_prefix_len 3

  @type event :: {:stdout, binary()} | {:stderr, binary()} | {:output, binary()}
  @type close_reason :: :normal | {:error, Error.t()}

  defmodule State do
    @moduledoc false
    defstruct [
      :ws_mod,
      :ws,
      :owner,
      :owner_ref,
      :idle_timeout,
      :idle_timer,
      :overall_timer,
      :max_buffer_bytes,
      :max_frames,
      :max_frame_bytes,
      # demux
      buf: <<>>,
      channel: nil,
      # delivery
      queue: :queue.new(),
      queued_bytes: 0,
      queued_frames: 0,
      waiter: nil,
      closed: nil
    ]
  end

  @doc """
  Open a log stream over an established websocket URL. Usually called
  through `ExDaytona.Session.open_log_stream/3`.

  ## Options

  - `:owner` — monitored owner pid (default: the caller)
  - `:ws_mod` — websocket transport module (default `ExDaytona.WebSocket`)
  - `:max_buffer_bytes` — cap on undelivered bytes (default `1_048_576`)
  - `:max_frames` — cap on undelivered events (default `10_000`)
  - `:max_frame_bytes` — cap on one websocket frame (default `1_048_576`)
  - `:idle_timeout` — ms without any frame before erroring (default `60_000`)
  - `:overall_timeout` — ms for the whole stream (default `:infinity`)
  - `:connect_timeout` — ms for the websocket upgrade (default `15_000`)
  """
  @spec open(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def open(url, api_key, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())

    case GenServer.start(__MODULE__, {url, api_key, owner, opts}) do
      {:ok, pid} ->
        case GenServer.call(pid, :await_ready, Keyword.get(opts, :connect_timeout, 15_000) + 1_000) do
          :ok -> {:ok, pid}
          {:error, %Error{} = error} -> {:error, error}
        end

      {:error, reason} ->
        {:error, Error.from(reason)}
    end
  catch
    :exit, reason -> {:error, %Error{message: "log stream open failed: #{inspect(reason)}"}}
  end

  @doc """
  The next event, waiting up to `timeout` ms.

  Returns `{:ok, {:stdout | :stderr | :output, binary}}` (`:output` =
  unlabeled bytes from daemons without channel marking),
  `{:closed, reason}` once
  the stream has ended and the buffer is drained (`reason` is `:normal`
  or `{:error, %ExDaytona.Error{}}` for overflow/timeout/transport
  failures), or `{:error, %ExDaytona.Error{}}` when `timeout` elapses
  with the stream still live.
  """
  @spec next(pid(), timeout()) :: {:ok, event()} | {:closed, close_reason()} | {:error, Error.t()}
  def next(stream, timeout \\ 5_000) do
    GenServer.call(stream, {:next, timeout}, wait_budget(timeout))
  catch
    :exit, {:normal, _} -> {:closed, :normal}
    :exit, {:noproc, _} -> {:closed, :normal}
    :exit, {:timeout, _} -> {:error, %Error{message: "log stream next/2 timed out"}}
  end

  defp wait_budget(:infinity), do: :infinity
  defp wait_budget(ms), do: ms + 1_000

  @doc """
  Close the stream (idempotent). Buffered undelivered events are
  discarded.
  """
  @spec close(pid()) :: :ok
  def close(stream) do
    if Process.alive?(stream), do: GenServer.cast(stream, :close)
    :ok
  end

  @doc """
  The stream's events as a lazy `Enumerable` — the idiomatic way to
  consume a log stream with `for`/`Enum`/`Stream`:

      {:ok, stream} = ExDaytona.Session.open_log_stream(session, cmd_id)

      for event <- ExDaytona.LogStream.events!(stream) do
        case event do
          {:stdout, bytes} -> IO.write(bytes)
          {:stderr, bytes} -> IO.write(:stderr, bytes)
          {:output, bytes} -> IO.write(bytes)
        end
      end

  Enumeration ends when the stream closes normally and **raises** the
  `ExDaytona.Error` when it closes abnormally (overflow, timeout,
  transport failure) — hence the `!`. Halting enumeration early
  (`Enum.take/2`, `Stream.take_while/2`, a `for` with `:halt`, ...)
  closes the underlying stream; so does finishing it.

  Options:

  - `:timeout` — max ms to wait for each event (default `:infinity`;
    the stream's own `idle_timeout`/`overall_timeout` still apply)
  """
  @spec events!(pid(), keyword()) :: Enumerable.t()
  def events!(stream, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    Stream.resource(
      fn -> stream end,
      fn stream ->
        case next(stream, timeout) do
          {:ok, event} -> {[event], stream}
          {:closed, :normal} -> {:halt, stream}
          {:closed, {:error, error}} -> raise error
          {:error, error} -> raise error
        end
      end,
      fn stream -> close(stream) end
    )
  end

  @doc """
  Collect events until the stream closes, returning
  `{:ok, %{stdout: binary, stderr: binary, closed: reason}}`. Convenience
  for short commands; long-lived follows should loop `next/2`.
  """
  @spec collect(pid(), timeout()) ::
          {:ok, %{stdout: binary(), stderr: binary(), output: binary(), closed: close_reason()}}
          | {:error, Error.t()}
  def collect(stream, timeout \\ 60_000) do
    do_collect(stream, timeout, %{stdout: [], stderr: [], output: []})
  end

  defp do_collect(stream, timeout, acc) do
    case next(stream, timeout) do
      {:ok, {channel, bytes}} ->
        do_collect(stream, timeout, Map.update!(acc, channel, &[&1, bytes]))

      {:closed, reason} ->
        {:ok,
         %{
           stdout: IO.iodata_to_binary(acc.stdout),
           stderr: IO.iodata_to_binary(acc.stderr),
           output: IO.iodata_to_binary(acc.output),
           closed: reason
         }}

      {:error, _} = error ->
        error
    end
  end

  ## GenServer ---------------------------------------------------------------

  @impl true
  def init({url, api_key, owner, opts}) do
    ws_mod = Keyword.get(opts, :ws_mod, ExDaytona.WebSocket)

    case ws_mod.connect(url, api_key, owner: self(), connect_timeout: Keyword.get(opts, :connect_timeout, 15_000)) do
      {:ok, ws} ->
        owner_ref = Process.monitor(owner)
        overall = Keyword.get(opts, :overall_timeout, :infinity)

        overall_timer =
          if overall != :infinity,
            do: Process.send_after(self(), :overall_timeout, overall)

        state = %State{
          ws_mod: ws_mod,
          ws: ws,
          owner: owner,
          owner_ref: owner_ref,
          idle_timeout: Keyword.get(opts, :idle_timeout, 60_000),
          overall_timer: overall_timer,
          max_buffer_bytes: Keyword.get(opts, :max_buffer_bytes, 1_048_576),
          max_frames: Keyword.get(opts, :max_frames, 10_000),
          max_frame_bytes: Keyword.get(opts, :max_frame_bytes, 1_048_576)
        }

        {:ok, reset_idle(state)}

      {:error, %Error{} = error} ->
        {:stop, {:connect_failed, error}}
    end
  end

  @impl true
  def handle_call(:await_ready, _from, state), do: {:reply, :ok, state}

  def handle_call({:next, timeout}, from, %State{} = state) do
    case pop(state) do
      {:value, event, state} ->
        {:reply, {:ok, event}, state}

      {:empty, %State{closed: nil} = state} ->
        # No data yet: park the caller (single-consumer contract).
        state = cancel_waiter(state, {:error, %Error{message: "superseded by a newer next/2 call"}})

        timer =
          if timeout != :infinity,
            do: Process.send_after(self(), {:waiter_timeout, from}, timeout)

        {:noreply, %{state | waiter: {from, timer}}}

      {:empty, %State{closed: reason} = state} ->
        {:reply, {:closed, reason}, state}
    end
  end

  @impl true
  def handle_cast(:close, %State{} = state) do
    state = shutdown(state, :normal)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_daytona_ws, ws, {frame_type, data}}, %State{ws: ws} = state)
      when frame_type in [:text, :binary] do
    data = if is_binary(data), do: data, else: IO.iodata_to_binary(data)

    if byte_size(data) > state.max_frame_bytes do
      error = %Error{
        code: "FRAME_TOO_LARGE",
        message: "log frame of #{byte_size(data)} bytes exceeds max_frame_bytes #{state.max_frame_bytes}"
      }

      {:noreply, shutdown(state, {:error, error})}
    else
      {:noreply, ingest_frame(state, data)}
    end
  end

  def handle_info({:ex_daytona_ws, ws, {:closed, reason}}, %State{ws: ws} = state) do
    close_reason =
      case reason do
        :normal -> :normal
        other -> {:error, %Error{message: "log stream connection closed: #{inspect(other)}", details: other}}
      end

    state = flush_partial(state)
    {:noreply, mark_closed(state, close_reason)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{owner_ref: ref} = state) do
    state = shutdown(state, :normal)
    {:stop, :normal, state}
  end

  def handle_info(:idle_timeout, %State{} = state) do
    error = %Error{message: "log stream idle for #{state.idle_timeout}ms", code: "IDLE_TIMEOUT"}
    {:noreply, shutdown(state, {:error, error})}
  end

  def handle_info(:overall_timeout, %State{} = state) do
    error = %Error{message: "log stream exceeded its overall timeout", code: "DEADLINE"}
    {:noreply, shutdown(state, {:error, error})}
  end

  def handle_info({:waiter_timeout, from}, %State{waiter: {from, _timer}} = state) do
    GenServer.reply(from, {:error, %Error{message: "log stream next/2 timed out"}})
    {:noreply, %{state | waiter: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{} = state) do
    close_ws(state)
    :ok
  end

  defp ingest_frame(state, data) do
    state = state |> reset_idle() |> demux(data)

    if state.queued_bytes > state.max_buffer_bytes or state.queued_frames > state.max_frames do
      error = %Error{
        code: "OVERFLOW",
        message:
          "undelivered log buffer exceeded bounds " <>
            "(#{state.queued_bytes} bytes / #{state.queued_frames} events) — consumer too slow"
      }

      shutdown(%{state | queue: :queue.new(), queued_bytes: 0, queued_frames: 0}, {:error, error})
    else
      deliver_to_waiter(state)
    end
  end

  ## Demultiplexing ----------------------------------------------------------

  # Port of the provider's stream protocol: 3-byte markers switch the
  # current channel (\\x01\\x01\\x01 -> stdout, \\x02\\x02\\x02 -> stderr);
  # a marker can arrive split across frames, so a trailing "unsafe region"
  # of partial-marker bytes is held back until more data arrives.
  defp demux(%State{} = state, data) do
    buf = state.buf <> data
    scan(state, buf)
  end

  defp scan(state, buf) do
    safe_len = safe_length(buf)

    if safe_len <= 0 do
      %{state | buf: buf}
    else
      si = index_of(buf, @stdout_prefix, safe_len)
      ei = index_of(buf, @stderr_prefix, safe_len)

      case nearest_marker(si, ei) do
        nil ->
          <<emit::binary-size(^safe_len), rest::binary>> = buf
          state |> enqueue_payload(emit) |> Map.put(:buf, rest) |> scan_continue()

        {index, channel, marker_len} ->
          <<emit::binary-size(^index), _marker::binary-size(^marker_len), rest::binary>> = buf

          state
          |> enqueue_payload(emit)
          |> Map.put(:channel, channel)
          |> Map.put(:buf, rest)
          |> scan(rest)
      end
    end
  end

  # After emitting the safe region with no marker found, stop scanning (the
  # remaining unsafe tail waits for more data).
  defp scan_continue(state), do: state

  defp safe_length(buf) when byte_size(buf) < @max_prefix_len, do: 0

  defp safe_length(buf) do
    # Hold back up to (marker length - 1) trailing marker bytes that could
    # be a split marker.
    size = byte_size(buf)
    last = :binary.at(buf, size - 1)

    cond do
      last not in [0x01, 0x02] ->
        size

      size >= @max_prefix_len + 1 ->
        second_last = :binary.at(buf, size - 2)
        if second_last in [0x01, 0x02], do: size - (@max_prefix_len - 1), else: size - 1

      true ->
        size - (@max_prefix_len - 1)
    end
  end

  defp index_of(_buf, _pattern, scope) when scope < @max_prefix_len, do: :nomatch

  defp index_of(buf, pattern, scope) do
    case :binary.match(buf, pattern, scope: {0, scope}) do
      {index, _len} -> index
      :nomatch -> :nomatch
    end
  end

  defp nearest_marker(:nomatch, :nomatch), do: nil
  defp nearest_marker(si, :nomatch), do: {si, :stdout, @max_prefix_len}
  defp nearest_marker(:nomatch, ei), do: {ei, :stderr, @max_prefix_len}

  defp nearest_marker(si, ei) when si < ei, do: {si, :stdout, @max_prefix_len}
  defp nearest_marker(_si, ei), do: {ei, :stderr, @max_prefix_len}

  defp enqueue_payload(state, <<>>), do: state

  # Bytes arriving before any channel marker: the daemon did not label
  # them (older daemons stream merged output without the mux protocol) —
  # deliver as {:output, bytes} rather than dropping or mislabeling.
  defp enqueue_payload(%State{channel: nil} = state, bytes) do
    %{
      state
      | queue: :queue.in({:output, bytes}, state.queue),
        queued_bytes: state.queued_bytes + byte_size(bytes),
        queued_frames: state.queued_frames + 1
    }
  end

  defp enqueue_payload(%State{} = state, bytes) do
    %{
      state
      | queue: :queue.in({state.channel, bytes}, state.queue),
        queued_bytes: state.queued_bytes + byte_size(bytes),
        queued_frames: state.queued_frames + 1
    }
  end

  # On close, any held-back partial-marker bytes belong to the current
  # channel.
  defp flush_partial(%State{buf: <<>>} = state), do: state

  defp flush_partial(%State{} = state) do
    state |> enqueue_payload(state.buf) |> Map.put(:buf, <<>>)
  end

  ## Delivery ----------------------------------------------------------------

  defp pop(%State{} = state) do
    case :queue.out(state.queue) do
      {{:value, {_channel, bytes} = event}, queue} ->
        {:value, event,
         %{
           state
           | queue: queue,
             queued_bytes: state.queued_bytes - byte_size(bytes),
             queued_frames: state.queued_frames - 1
         }}

      {:empty, _} ->
        {:empty, state}
    end
  end

  defp deliver_to_waiter(%State{waiter: nil} = state), do: state

  defp deliver_to_waiter(%State{waiter: {from, timer}} = state) do
    case pop(state) do
      {:value, event, state} ->
        if timer, do: Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, event})
        %{state | waiter: nil}

      {:empty, state} ->
        state
    end
  end

  defp cancel_waiter(%State{waiter: nil} = state, _reply), do: state

  defp cancel_waiter(%State{waiter: {from, timer}} = state, reply) do
    if timer, do: Process.cancel_timer(timer)
    GenServer.reply(from, reply)
    %{state | waiter: nil}
  end

  defp mark_closed(%State{} = state, reason) do
    state = cancel_timers(state)
    state = %{state | closed: state.closed || reason}
    notify_waiter_of_close(state)
  end

  defp notify_waiter_of_close(%State{waiter: nil} = state), do: state

  defp notify_waiter_of_close(%State{waiter: {from, timer}} = state) do
    case pop(state) do
      {:value, event, state} ->
        if timer, do: Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, event})
        %{state | waiter: nil}

      {:empty, state} ->
        if timer, do: Process.cancel_timer(timer)
        GenServer.reply(from, {:closed, state.closed})
        %{state | waiter: nil}
    end
  end

  defp shutdown(%State{} = state, reason) do
    close_ws(state)
    mark_closed(state, reason)
  end

  defp close_ws(%State{ws: nil}), do: :ok
  defp close_ws(%State{ws_mod: mod, ws: ws}), do: mod.close(ws)

  defp reset_idle(%State{} = state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)

    timer =
      if state.idle_timeout != :infinity,
        do: Process.send_after(self(), :idle_timeout, state.idle_timeout)

    %{state | idle_timer: timer}
  end

  defp cancel_timers(%State{} = state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    if state.overall_timer, do: Process.cancel_timer(state.overall_timer)
    %{state | idle_timer: nil, overall_timer: nil}
  end
end
