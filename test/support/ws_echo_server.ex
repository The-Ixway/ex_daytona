defmodule WsEchoServer do
  @moduledoc """
  Minimal local websocket server for exercising `ExDaytona.WebSocket` in
  tests (Bypass can't upgrade to websockets; cowboy — already here as a
  Bypass dependency — can).

  Every path upgrades. Frames are echoed back prefixed with `"echo:"`,
  and the request's `authorization` header is reported on connect as
  `auth:<value>` so tests can assert authentication reached the server.
  """

  defmodule Handler do
    @moduledoc false
    @behaviour :cowboy_websocket

    @impl true
    def init(req, _state) do
      auth = :cowboy_req.header("authorization", req, "none")
      {:cowboy_websocket, req, %{auth: auth}}
    end

    @impl true
    def websocket_init(state) do
      {[{:text, "auth:" <> state.auth}], state}
    end

    @impl true
    def websocket_handle({:text, data}, state), do: {[{:text, "echo:" <> data}], state}
    def websocket_handle({:binary, data}, state), do: {[{:binary, "echo:" <> data}], state}
    def websocket_handle(_frame, state), do: {[], state}

    @impl true
    def websocket_info(_message, state), do: {[], state}
  end

  defmodule InterpreterHandler do
    @moduledoc false
    # Speaks the Daytona code-interpreter websocket protocol: the client
    # sends a JSON request; the server streams JSON chunks
    # ({"type": "stdout"|"stderr"|"error", ...}) and closes. Replies are
    # derived from the request's code so tests can assert round-tripping.
    @behaviour :cowboy_websocket

    @impl true
    def init(req, _state), do: {:cowboy_websocket, req, %{}}

    @impl true
    def websocket_init(state), do: {[], state}

    @impl true
    def websocket_handle({:text, data}, state) do
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

      frames = Enum.map(chunks, &{:text, JSON.encode!(&1)}) ++ [{:close, 1000, ""}]
      {frames, state}
    end

    def websocket_handle(_frame, state), do: {[], state}

    @impl true
    def websocket_info(_message, state), do: {[], state}
  end

  @doc """
  Start a websocket echo listener on an ephemeral port. Returns the port;
  the listener is stopped automatically via `ExUnit.Callbacks.on_exit/1`.
  """
  def start, do: start_with(Handler)

  @doc """
  Start a listener speaking the code-interpreter protocol instead of
  echoing (see `InterpreterHandler`).
  """
  def start_interpreter, do: start_with(InterpreterHandler)

  defp start_with(handler) do
    name = :"ws_echo_#{System.unique_integer([:positive])}"
    dispatch = :cowboy_router.compile([{:_, [{:_, handler, []}]}])

    {:ok, _pid} = :cowboy.start_clear(name, [port: 0], %{env: %{dispatch: dispatch}})
    ExUnit.Callbacks.on_exit(fn -> :cowboy.stop_listener(name) end)

    :ranch.get_port(name)
  end
end
