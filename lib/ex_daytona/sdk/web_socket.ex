defmodule ExDaytona.WebSocket do
  @moduledoc """
  WebSocket client for Daytona's websocket endpoints (PTY sessions,
  interpreter execution).

  A connection is a process; frames arrive as messages to its owner
  (by default, the process that called `connect/3`):

  - `{:ex_daytona_ws, pid, {:text, data}}` / `{:ex_daytona_ws, pid, {:binary, data}}`
  - `{:ex_daytona_ws, pid, {:closed, reason}}` — the connection ended;
    the process exits normally afterwards

  Usually used through `ExDaytona.Pty` rather than directly.
  """

  use GenServer

  alias ExDaytona.Error

  @doc """
  Open a websocket connection to `url` (an `http(s)://` or `ws(s)://` URL —
  https is converted to wss) authenticated with `api_key`.

  ## Options

  - `:owner` — the pid that receives frame messages (default: the caller)
  - `:connect_timeout` — milliseconds to wait for the upgrade
    (default `15_000`)
  """
  @spec connect(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def connect(url, api_key, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    timeout = Keyword.get(opts, :connect_timeout, 15_000)

    case GenServer.start(__MODULE__, {url, api_key, owner}) do
      {:ok, pid} ->
        case GenServer.call(pid, :await_upgrade, timeout) do
          :ok -> {:ok, pid}
          {:error, %Error{} = error} -> {:error, error}
        end

      {:error, reason} ->
        {:error, Error.from(reason)}
    end
  catch
    :exit, reason -> {:error, %Error{message: "websocket connect failed: #{inspect(reason)}"}}
  end

  @doc """
  Send a text frame.
  """
  @spec send_text(pid(), iodata()) :: :ok | {:error, Error.t()}
  def send_text(pid, data), do: GenServer.call(pid, {:send, {:text, IO.iodata_to_binary(data)}})

  @doc """
  Send a binary frame.
  """
  @spec send_binary(pid(), iodata()) :: :ok | {:error, Error.t()}
  def send_binary(pid, data),
    do: GenServer.call(pid, {:send, {:binary, IO.iodata_to_binary(data)}})

  @doc """
  Close the connection (sends a close frame and stops the process).
  """
  @spec close(pid()) :: :ok
  def close(pid) do
    if Process.alive?(pid), do: GenServer.cast(pid, :close)
    :ok
  end

  ## GenServer ---------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct [:conn, :websocket, :request_ref, :owner, :caller, :status, :resp_headers]
  end

  @impl true
  def init({url, api_key, owner}) do
    uri = URI.parse(url)

    {scheme, ws_scheme} =
      case uri.scheme do
        s when s in ["https", "wss"] -> {:https, :wss}
        _ -> {:http, :ws}
      end

    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    # HTTP/1-only: Mint.WebSocket over HTTP/2 requires server support for
    # RFC 8441, which proxies commonly lack.
    with {:ok, conn} <-
           Mint.HTTP.connect(scheme, uri.host, port, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path, [
             {"authorization", "Bearer " <> api_key}
           ]) do
      {:ok, %State{conn: conn, request_ref: ref, owner: owner}}
    else
      {:error, reason} -> {:stop, {:connect_failed, reason}}
      {:error, _conn, reason} -> {:stop, {:connect_failed, reason}}
    end
  end

  @impl true
  def handle_call(:await_upgrade, from, %State{} = state) do
    if state.websocket do
      {:reply, :ok, state}
    else
      {:noreply, %{state | caller: from}}
    end
  end

  def handle_call({:send, _frame}, _from, %State{websocket: nil} = state) do
    {:reply, {:error, %Error{message: "websocket is not connected"}}, state}
  end

  def handle_call({:send, frame}, _from, %State{} = state) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} ->
            {:reply, :ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            {:reply, {:error, Error.from(reason)}, %{state | conn: conn, websocket: websocket}}
        end

      {:error, websocket, reason} ->
        {:reply, {:error, Error.from(reason)}, %{state | websocket: websocket}}
    end
  end

  @impl true
  def handle_cast(:close, %State{} = state) do
    state = send_close(state)
    notify_closed(state, :normal)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(message, %State{} = state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{state | conn: conn})

      {:error, conn, reason, _responses} ->
        state = %{state | conn: conn}
        reply_caller(state, {:error, Error.from(reason)})
        notify_closed(state, reason)
        {:stop, :normal, state}

      :unknown ->
        {:noreply, state}
    end
  end

  defp handle_responses(responses, state) do
    Enum.reduce_while(responses, {:noreply, state}, fn response, {:noreply, state} ->
      case handle_response(response, state) do
        {:noreply, state} -> {:cont, {:noreply, state}}
        {:stop, reason, state} -> {:halt, {:stop, reason, state}}
      end
    end)
  end

  # no_match: dialyzer over-refines Mint's opaque private connection state
  # and concludes Mint.WebSocket.new/4 can never succeed from here; the
  # upgrade path is exercised by unit tests against a real cowboy websocket
  # server and verified live against Daytona's PTY endpoint.
  @dialyzer {:no_match, handle_response: 2}

  defp handle_response({:status, ref, status}, %State{request_ref: ref} = state) do
    {:noreply, %{state | status: status}}
  end

  defp handle_response({:headers, ref, headers}, %State{request_ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, headers) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}
        reply_caller(state, :ok)
        {:noreply, %{state | caller: nil}}

      {:error, conn, reason} ->
        state = %{state | conn: conn}

        reply_caller(
          state,
          {:error,
           %Error{
             status: state.status,
             message: "websocket upgrade failed: #{inspect(reason)}",
             details: reason
           }}
        )

        {:stop, :normal, state}
    end
  end

  defp handle_response({:data, ref, data}, %State{request_ref: ref, websocket: ws} = state)
       when not is_nil(ws) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}

        if Enum.any?(frames, &match?({:close, _, _}, &1)) do
          deliver_frames(frames, state)
          notify_closed(state, :normal)
          {:stop, :normal, state}
        else
          deliver_frames(frames, state)
          {:noreply, state}
        end

      {:error, websocket, reason} ->
        state = %{state | websocket: websocket}
        notify_closed(state, reason)
        {:stop, :normal, state}
    end
  end

  # Mint emits {:done, ref} immediately after a 101 upgrade's headers on
  # HTTP/1 — with the websocket established it does NOT mean the connection
  # closed (that arrives as a close frame or a transport error).
  defp handle_response({:done, ref}, %State{request_ref: ref, websocket: nil} = state) do
    notify_closed(state, :normal)
    {:stop, :normal, state}
  end

  defp handle_response({:done, ref}, %State{request_ref: ref} = state), do: {:noreply, state}

  defp handle_response(_other, state), do: {:noreply, state}

  defp deliver_frames(frames, %State{owner: owner}) do
    Enum.each(frames, fn
      {:text, data} -> send(owner, {:ex_daytona_ws, self(), {:text, data}})
      {:binary, data} -> send(owner, {:ex_daytona_ws, self(), {:binary, data}})
      {:ping, _} -> :ok
      {:pong, _} -> :ok
      {:close, _code, _reason} -> :ok
    end)
  end

  defp send_close(%State{websocket: nil} = state), do: state

  defp send_close(%State{} = state) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, :close),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      %{state | conn: conn, websocket: websocket}
    else
      _ -> state
    end
  end

  defp notify_closed(%State{owner: owner}, reason) do
    send(owner, {:ex_daytona_ws, self(), {:closed, reason}})
  end

  defp reply_caller(%State{caller: nil}, _reply), do: :ok
  defp reply_caller(%State{caller: caller}, reply), do: GenServer.reply(caller, reply)
end
