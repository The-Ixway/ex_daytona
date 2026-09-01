defmodule WsEchoServer do
  @moduledoc """
  Local websocket servers for exercising `ExDaytona.WebSocket` in tests,
  running on Bandit + WebSock (pure Elixir).

  `start/0` serves an echo handler: every path upgrades, frames come back
  prefixed with `"echo:"`, and the request's `authorization` header is
  reported on connect as `auth:<value>`.

  `start_interpreter/0` speaks the Daytona code-interpreter protocol
  instead: the client sends a JSON request, the server streams JSON
  chunks (`{"type": "stdout"|"stderr"|"error", ...}`) and closes.
  """

  defmodule EchoSock do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(state), do: {:push, {:text, "auth:" <> state.auth}, state}

    @impl true
    def handle_in({data, opcode: :text}, state), do: {:push, {:text, "echo:" <> data}, state}
    def handle_in({data, opcode: :binary}, state), do: {:push, {:binary, "echo:" <> data}, state}

    @impl true
    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  defmodule InterpreterSock do
    @moduledoc false
    # Replies to the request's code so tests can assert round-tripping.
    @behaviour WebSock

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_in({data, opcode: :text}, state) do
      request = JSON.decode!(data)
      code = request["code"] || ""

      chunks =
        [
          %{type: "stdout", text: "ran:" <> code},
          %{type: "stdout", text: " ctx:" <> (request["contextId"] || "default")}
        ] ++
          if String.contains?(code, "raise") do
            [%{type: "error", name: "RuntimeError", value: "boom", traceback: "trace..."}]
          else
            [%{type: "stderr", text: "warn\n"}]
          end

      frames = Enum.map(chunks, &{:text, JSON.encode!(&1)})
      {:stop, :normal, {1000, ""}, frames, state}
    end

    def handle_in(_frame, state), do: {:ok, state}

    @impl true
    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  defmodule UpgradePlug do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(handler), do: handler

    @impl true
    def call(conn, handler) do
      auth =
        case Plug.Conn.get_req_header(conn, "authorization") do
          [value | _] -> value
          [] -> "none"
        end

      WebSockAdapter.upgrade(conn, handler, %{auth: auth}, [])
    end
  end

  @doc """
  Start a websocket echo listener on an ephemeral port. Returns the port;
  the listener is stopped automatically via `ExUnit.Callbacks.on_exit/1`.
  """
  def start, do: start_with(EchoSock)

  @doc """
  Start a listener speaking the code-interpreter protocol instead of
  echoing (see `InterpreterSock`).
  """
  def start_interpreter, do: start_with(InterpreterSock)

  @doc """
  Stop every listener this process started (for disconnect tests).
  """
  def stop_all do
    Process.get(:ws_echo_listeners, [])
    |> Enum.each(fn server ->
      if Process.alive?(server), do: stop_server(server)
    end)

    Process.put(:ws_echo_listeners, [])
    :ok
  end

  defp start_with(handler) do
    {:ok, server} =
      Bandit.start_link(plug: {UpgradePlug, handler}, port: 0, startup_log: false)

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    ExUnit.Callbacks.on_exit(fn -> stop_server(server) end)
    Process.put(:ws_echo_listeners, [server | Process.get(:ws_echo_listeners, [])])

    port
  end

  # Stopping a listener with live websocket connections can exit with
  # :shutdown as the acceptors are torn down — that's fine in teardown.
  defp stop_server(server) do
    if Process.alive?(server), do: Supervisor.stop(server)
  catch
    :exit, _ -> :ok
  end
end
