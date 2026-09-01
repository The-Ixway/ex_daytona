defmodule ExDaytona.Pty do
  @moduledoc """
  Interactive PTY (pseudo-terminal) sessions inside a sandbox.

  A PTY is a real terminal: interactive programs (shells, REPLs, editors,
  anything that needs a TTY) run in it, and I/O flows over a websocket.

      {:ok, pty} = ExDaytona.Pty.create(sandbox, cols: 120, rows: 30)
      {:ok, ws} = ExDaytona.Pty.connect(pty)

      :ok = ExDaytona.Pty.send_input(ws, "echo hello\\n")

      receive do
        {:ex_daytona_ws, ^ws, {:binary, output}} -> IO.write(output)
      end

      :ok = ExDaytona.Pty.resize(pty, 200, 50)
      :ok = ExDaytona.Pty.disconnect(ws)
      :ok = ExDaytona.Pty.delete(pty)

  Terminal output arrives at the connecting process as
  `{:ex_daytona_ws, ws_pid, {:binary, data}}` messages (see
  `ExDaytona.WebSocket` for the full message shapes).
  """

  alias ExDaytona.Api
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Sandbox
  alias ExDaytona.Toolbox
  alias ExDaytona.WebSocket

  @enforce_keys [:sandbox, :id]
  defstruct [:sandbox, :id]

  @typedoc "A PTY session bound to its sandbox."
  @type t :: %__MODULE__{sandbox: Sandbox.t(), id: String.t()}

  @doc """
  Create a PTY session.

  ## Options

  - `:id` — session id (default: a generated `"ex-daytona-pty-"` id)
  - `:cols` / `:rows` — terminal size (server defaults apply when omitted)
  - `:cwd` — working directory
  - `:env` — environment variables (map)
  - `:lazy_start` — don't start the shell until the first connect
  """
  @spec create(Sandbox.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def create(%Sandbox{} = sandbox, opts \\ []) do
    id = Keyword.get(opts, :id, "ex-daytona-pty-#{System.unique_integer([:positive])}")

    request = %Model.PtyCreateRequest{
      id: id,
      cols: opts[:cols],
      rows: opts[:rows],
      cwd: opts[:cwd],
      envs: opts[:env],
      lazyStart: opts[:lazy_start]
    }

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, %Model.PtyCreateResponse{sessionId: session_id}} <-
           Error.normalize(Api.Process.create_pty_session(conn, request)) do
      {:ok, %__MODULE__{sandbox: sandbox, id: session_id || id}}
    end
  end

  @doc """
  Open the PTY's websocket. Terminal output is delivered to the calling
  process (override with `:owner`) as `{:ex_daytona_ws, ws, {:binary, data}}`
  messages; `{:ex_daytona_ws, ws, {:closed, reason}}` signals the end.

  Options are passed to `ExDaytona.WebSocket.connect/3` (`:owner`,
  `:connect_timeout`).
  """
  @spec connect(t(), keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def connect(%__MODULE__{sandbox: sandbox, id: id}, opts \\ []) do
    with {:ok, base_url} <- toolbox_base_url(sandbox) do
      ws_mod = ExDaytona.Client.transport(sandbox.client, :websocket)
      url = base_url <> "/process/pty/#{id}/connect"

      case ws_mod.connect(url, sandbox.client.api_key, opts) do
        {:ok, pid} when ws_mod == ExDaytona.WebSocket ->
          {:ok, pid}

        {:ok, pid} ->
          {:ok, %ExDaytona.Transport.WSHandle{mod: ws_mod, pid: pid}}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Write input to the terminal (what a user would type). `ws` is the
  connection from `connect/2`.
  """
  @spec send_input(pid() | ExDaytona.Transport.WSHandle.t(), iodata()) ::
          :ok | {:error, Error.t()}
  def send_input(ws, data) when is_pid(ws), do: WebSocket.send_binary(ws, data)

  def send_input(%ExDaytona.Transport.WSHandle{mod: mod, pid: pid}, data),
    do: mod.send_binary(pid, data)

  @doc """
  Close the websocket connection (the PTY session keeps running — use
  `delete/1` to kill it).
  """
  @spec disconnect(pid() | ExDaytona.Transport.WSHandle.t()) :: :ok
  def disconnect(ws) when is_pid(ws), do: WebSocket.close(ws)

  def disconnect(%ExDaytona.Transport.WSHandle{mod: mod, pid: pid}), do: mod.close(pid)

  @doc """
  Resize the terminal.
  """
  @spec resize(t(), pos_integer(), pos_integer()) ::
          {:ok, Model.PtySessionInfo.t()} | {:error, Error.t()}
  def resize(%__MODULE__{sandbox: sandbox, id: id}, cols, rows)
      when is_integer(cols) and is_integer(rows) do
    request = %Model.PtyResizeRequest{cols: cols, rows: rows}

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox) do
      Error.normalize(Api.Process.resize_pty_session(conn, id, request))
    end
  end

  @doc """
  The PTY's current state as an `ExDaytona.Model.PtySessionInfo`.
  """
  @spec info(t()) :: {:ok, Model.PtySessionInfo.t()} | {:error, Error.t()}
  def info(%__MODULE__{sandbox: sandbox, id: id}) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox) do
      Error.normalize(Api.Process.get_pty_session(conn, id))
    end
  end

  @doc """
  List the sandbox's PTY sessions as `ExDaytona.Model.PtySessionInfo`
  structs.
  """
  @spec list(Sandbox.t()) :: {:ok, [Model.PtySessionInfo.t()]} | {:error, Error.t()}
  def list(%Sandbox{} = sandbox) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, %Model.PtyListResponse{sessions: sessions}} <-
           Error.normalize(Api.Process.list_pty_sessions(conn)) do
      {:ok, sessions || []}
    end
  end

  @doc """
  Kill the PTY session. Returns `:ok`.
  """
  @spec delete(t()) :: :ok | {:error, Error.t()}
  def delete(%__MODULE__{sandbox: sandbox, id: id}) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, _} <- Error.normalize(Api.Process.delete_pty_session(conn, id)) do
      :ok
    end
  end

  defp toolbox_base_url(%Sandbox{info: info}) do
    {:ok, Toolbox.base_url(info)}
  rescue
    e in ArgumentError -> {:error, %Error{message: Exception.message(e), details: e}}
  end
end
