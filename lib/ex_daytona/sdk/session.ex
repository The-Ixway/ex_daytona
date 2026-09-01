defmodule ExDaytona.Session do
  @moduledoc """
  Long-running command sessions inside a sandbox.

  Where `ExDaytona.Sandbox.exec/3` runs one command to completion, a
  session is a persistent shell: commands share state (working directory,
  environment) and can run asynchronously — start a command, poll or
  stream its logs, and collect its exit code when it finishes.

      {:ok, session} = ExDaytona.Session.create(sandbox)

      # Synchronous: waits for the command
      {:ok, %{exit_code: 0, output: out}} = ExDaytona.Session.run(session, "echo hi")

      # Asynchronous: start, follow the logs, then reap the exit code
      {:ok, cmd_id} = ExDaytona.Session.run_async(session, "sleep 5 && echo done")
      :ok = ExDaytona.Session.stream_logs(session, cmd_id, &IO.write/1)
      {:ok, %{exit_code: 0}} = ExDaytona.Session.await(session, cmd_id)

      :ok = ExDaytona.Session.delete(session)
  """

  alias ExDaytona.Api
  alias ExDaytona.Connection
  alias ExDaytona.Error
  alias ExDaytona.HTTPStream
  alias ExDaytona.Model
  alias ExDaytona.Sandbox
  alias ExDaytona.Toolbox

  @enforce_keys [:sandbox, :id]
  defstruct [:sandbox, :id]

  @typedoc "A session bound to the sandbox it runs in."
  @type t :: %__MODULE__{sandbox: Sandbox.t(), id: String.t()}

  @doc """
  Create a session in the sandbox.

  Options: `:id` — the session id (default: a generated
  `"ex-daytona-"` id).
  """
  @spec create(Sandbox.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def create(%Sandbox{} = sandbox, opts \\ []) do
    id = Keyword.get(opts, :id, "ex-daytona-#{System.unique_integer([:positive])}")

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, _} <-
           Error.normalize(
             Api.Process.create_session(conn, %Model.CreateSessionRequest{sessionId: id}, response: :full)
           ) do
      {:ok, %__MODULE__{sandbox: sandbox, id: id}}
    end
  end

  @doc """
  List the sandbox's sessions as `ExDaytona.Model.Session` structs.
  """
  @spec list(Sandbox.t()) :: {:ok, [Model.Session.t()]} | {:error, Error.t()}
  def list(%Sandbox{} = sandbox) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, sessions} <- Error.normalize(Api.Process.list_sessions(conn, response: :full)) do
      {:ok, List.wrap(sessions)}
    end
  end

  @doc """
  Fetch a session's current state (its command history) as an
  `ExDaytona.Model.Session`.
  """
  @spec get(t()) :: {:ok, Model.Session.t()} | {:error, Error.t()}
  def get(%__MODULE__{sandbox: sandbox, id: id}) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox) do
      Error.normalize(Api.Process.get_session(conn, id, response: :full))
    end
  end

  @doc """
  Delete the session. Returns `:ok`.
  """
  @spec delete(t()) :: :ok | {:error, Error.t()}
  def delete(%__MODULE__{sandbox: sandbox, id: id}) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, _} <- Error.normalize(Api.Process.delete_session(conn, id, response: :full)) do
      :ok
    end
  end

  @doc """
  Run a command in the session and wait for it to finish.

  Returns `{:ok, %{cmd_id, exit_code, output, stdout, stderr}}`.
  """
  @spec run(t(), String.t()) ::
          {:ok,
           %{
             cmd_id: String.t() | nil,
             exit_code: integer() | nil,
             output: String.t() | nil,
             stdout: String.t() | nil,
             stderr: String.t() | nil
           }}
          | {:error, Error.t()}
  def run(%__MODULE__{sandbox: sandbox, id: id}, command) when is_binary(command) do
    request = %Model.SessionExecuteRequest{command: command, runAsync: false}

    ExDaytona.Telemetry.span(
      [:session, :run],
      %{sandbox_id: Sandbox.id(sandbox), session_id: id},
      fn ->
        with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
             {:ok, %Model.SessionExecuteResponse{} = response} <-
               Error.normalize(Api.Process.session_execute_command(conn, id, request, response: :full)) do
          {:ok,
           %{
             cmd_id: response.cmdId,
             exit_code: response.exitCode,
             output: response.output,
             stdout: response.stdout,
             stderr: response.stderr
           }}
        end
      end,
      &Sandbox.exit_code_metadata/1
    )
  end

  @doc """
  Start a command in the session without waiting. Returns
  `{:ok, cmd_id}` — follow it with `stream_logs/4`, `logs/2`, and
  `await/3`.
  """
  @spec run_async(t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def run_async(%__MODULE__{sandbox: sandbox, id: id}, command, opts \\ [])
      when is_binary(command) do
    request = %Model.SessionExecuteRequest{
      command: command,
      runAsync: true,
      suppressInputEcho: opts[:suppress_input_echo]
    }

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, %Model.SessionExecuteResponse{cmdId: cmd_id}} <-
           Error.normalize(Api.Process.session_execute_command(conn, id, request, response: :full)) do
      {:ok, cmd_id}
    end
  end

  @doc """
  A command's current state (`ExDaytona.Model.Command`) — `exitCode` is
  `nil` while it is still running.
  """
  @spec command(t(), String.t()) :: {:ok, Model.Command.t()} | {:error, Error.t()}
  def command(%__MODULE__{sandbox: sandbox, id: id}, cmd_id) when is_binary(cmd_id) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox) do
      Error.normalize(Api.Process.get_session_command(conn, id, cmd_id, response: :full))
    end
  end

  @doc """
  Poll until the command finishes, then return
  `{:ok, %{exit_code: integer, command: String.t()}}`.

  Options: `:timeout` (default `120_000` ms), `:poll_interval`
  (default `1_000` ms).
  """
  @spec await(t(), String.t(), keyword()) ::
          {:ok, %{exit_code: integer(), command: String.t() | nil}} | {:error, Error.t()}
  def await(%__MODULE__{} = session, cmd_id, opts \\ []) when is_binary(cmd_id) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    interval = Keyword.get(opts, :poll_interval, 1_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_command(session, cmd_id, interval, deadline)
  end

  @doc """
  The logs a command has produced so far, as a binary (stdout and stderr
  merged, as the sandbox emits them).

  Note: the OpenAPI spec declares a JSON model for this endpoint, but the
  live server returns `text/plain` — so this bypasses the generated
  operation and reads the raw body.
  """
  @spec logs(t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def logs(%__MODULE__{sandbox: sandbox, id: id}, cmd_id) when is_binary(cmd_id) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, %Tesla.Env{body: body}} <-
           Error.normalize(
             Connection.request(conn,
               method: :get,
               url: "/process/session/#{id}/command/#{cmd_id}/logs"
             )
           ) do
      {:ok, body}
    end
  end

  @doc """
  Open a structured, bounded log stream for a command — separate
  `:stdout`/`:stderr` events over the provider's websocket protocol,
  pull-based via `ExDaytona.LogStream.next/2`. See `ExDaytona.LogStream`
  for the full contract (ownership, bounds, timeouts, close semantics).

  Options are passed to `ExDaytona.LogStream.open/3`
  (`:owner`, `:max_buffer_bytes`, `:max_frames`, `:max_frame_bytes`,
  `:idle_timeout`, `:overall_timeout`, `:connect_timeout`).
  """
  @spec open_log_stream(t(), String.t(), keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def open_log_stream(%__MODULE__{sandbox: sandbox, id: id}, cmd_id, opts \\ [])
      when is_binary(cmd_id) do
    with {:ok, base_url} <- toolbox_base_url(sandbox) do
      url = base_url <> "/process/session/#{id}/command/#{cmd_id}/logs?follow=true"

      opts =
        Keyword.put_new(opts, :ws_mod, ExDaytona.Client.transport(sandbox.client, :websocket))

      ExDaytona.LogStream.open(url, sandbox.client.api_key, opts)
    end
  end

  @doc """
  Follow a command's logs in real time: `fun` is invoked with each chunk
  as the sandbox produces it, and the call returns `:ok` when the stream
  closes (the command finished). Returning `:halt` from `fun` cancels
  the stream.

  > #### Merged output {: .info}
  >
  > This HTTP follow delivers stdout and stderr merged, exactly as 0.1.0
  > did. For separated, bounded, pull-based streaming use
  > `open_log_stream/3` / `ExDaytona.LogStream`.

  Options: `:timeout` — max milliseconds to wait between chunks
  (default `:infinity`); `:deadline` — overall milliseconds for the
  stream.
  """
  @spec stream_logs(t(), String.t(), (binary() -> any()), keyword()) ::
          :ok | {:error, Error.t()}
  def stream_logs(%__MODULE__{sandbox: sandbox, id: id}, cmd_id, fun, opts \\ [])
      when is_binary(cmd_id) and is_function(fun, 1) do
    with {:ok, base_url} <- toolbox_base_url(sandbox) do
      url =
        base_url <>
          "/process/session/#{id}/command/#{cmd_id}/logs?follow=true"

      opts =
        Keyword.put_new(opts, :transport, ExDaytona.Client.transport(sandbox.client, :http_stream))

      HTTPStream.get(url, sandbox.client.api_key, fun, opts)
    end
  end

  @doc """
  Send input to an interactive command's stdin (e.g. answering a
  confirmation prompt). Returns `:ok`.
  """
  @spec send_input(t(), String.t(), iodata()) :: :ok | {:error, Error.t()}
  def send_input(%__MODULE__{sandbox: sandbox, id: id}, cmd_id, data) when is_binary(cmd_id) do
    request = %Model.SessionSendInputRequest{data: IO.iodata_to_binary(data)}

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox) do
      attempt_send_input(conn, id, cmd_id, request, 6)
    end
  end

  # The daemon creates a command's stdin pipe shortly after the command
  # starts; input sent immediately after run_async/3 can race it ("failed
  # to open input pipe ... no such file or directory") — observed to take
  # over a second on a fresh command. Retry that specific failure for a
  # couple of seconds instead of surfacing the race to callers.
  defp attempt_send_input(conn, id, cmd_id, request, attempts_left) do
    case Error.normalize(Api.Process.send_input(conn, id, cmd_id, request, response: :full)) do
      {:ok, _} ->
        :ok

      {:error, %Error{message: message} = error} ->
        if attempts_left > 1 and is_binary(message) and message =~ "input.pipe" do
          Process.sleep(500)
          attempt_send_input(conn, id, cmd_id, request, attempts_left - 1)
        else
          {:error, error}
        end
    end
  end

  @doc """
  The sandbox's entrypoint session (where a configured entrypoint runs),
  as an `ExDaytona.Model.Session`.
  """
  @spec entrypoint(Sandbox.t()) :: {:ok, Model.Session.t()} | {:error, Error.t()}
  def entrypoint(%Sandbox{} = sandbox) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox) do
      Error.normalize(Api.Process.get_entrypoint_session(conn, response: :full))
    end
  end

  @doc """
  The entrypoint's logs so far, as a binary (fetched raw — see `logs/2`
  for why the generated operation is bypassed).
  """
  @spec entrypoint_logs(Sandbox.t()) :: {:ok, binary()} | {:error, Error.t()}
  def entrypoint_logs(%Sandbox{} = sandbox) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, %Tesla.Env{body: body}} <-
           Error.normalize(Connection.request(conn, method: :get, url: "/process/session/entrypoint/logs")) do
      {:ok, body}
    end
  end

  defp toolbox_base_url(%Sandbox{info: info}) do
    {:ok, Toolbox.base_url(info)}
  rescue
    e in ArgumentError -> {:error, %Error{message: Exception.message(e), details: e}}
  end

  defp poll_command(session, cmd_id, interval, deadline) do
    case command(session, cmd_id) do
      {:ok, %Model.Command{exitCode: exit_code} = cmd} when is_integer(exit_code) ->
        {:ok, %{exit_code: exit_code, command: cmd.command}}

      {:ok, %Model.Command{}} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, %Error{message: "timed out waiting for session command #{cmd_id} to finish"}}
        else
          Process.sleep(interval)
          poll_command(session, cmd_id, interval, deadline)
        end

      {:error, _} = error ->
        error
    end
  end
end
