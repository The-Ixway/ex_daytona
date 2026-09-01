defmodule ExDaytona.CodeInterpreter do
  @moduledoc """
  Stateful Python execution inside a sandbox.

  Unlike `ExDaytona.Sandbox.run_code/3` (fresh interpreter per run), the
  code interpreter keeps state — variables, imports, definitions —
  between runs, optionally isolated into named contexts:

      {:ok, %{}} = ExDaytona.CodeInterpreter.run(sandbox, "counter = 41")
      {:ok, %{stdout: "42\\n"}} = ExDaytona.CodeInterpreter.run(sandbox, "counter += 1\\nprint(counter)")

      # Isolated contexts
      {:ok, ctx} = ExDaytona.CodeInterpreter.create_context(sandbox, cwd: "/workspace")
      {:ok, _} = ExDaytona.CodeInterpreter.run(sandbox, "x = 1", context: ctx)
      :ok = ExDaytona.CodeInterpreter.delete_context(sandbox, ctx)

  Execution streams over a websocket: pass `:on_stdout` / `:on_stderr`
  callbacks to observe output in real time; the aggregated result is
  returned either way as `%{stdout, stderr, error}` (`error` is
  `%{name, value, traceback}` when the code raised, else `nil`).
  """

  alias ExDaytona.Api
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Sandbox
  alias ExDaytona.Toolbox

  @type execution_error :: %{name: String.t(), value: String.t(), traceback: String.t()}
  @type result :: %{
          stdout: String.t(),
          stderr: String.t(),
          error: execution_error() | nil
        }

  @doc """
  Execute Python code with persistent interpreter state.

  ## Options

  - `:context` — an `ExDaytona.Model.InterpreterContext` (or its id) to
    run in (default: the interpreter's default context)
  - `:env` — environment variables for this run (map)
  - `:timeout` — API-side execution timeout in seconds
  - `:on_stdout` / `:on_stderr` — `fun(text)` streaming callbacks
  - `:on_error` — `fun(%{name, value, traceback})` callback
  - `:receive_timeout` — max milliseconds to wait for the run to finish
    client-side (default `300_000`)
  """
  @spec run(Sandbox.t(), String.t(), keyword()) :: {:ok, result()} | {:error, Error.t()}
  def run(%Sandbox{} = sandbox, code, opts \\ []) when is_binary(code) do
    receive_timeout = Keyword.get(opts, :receive_timeout, 300_000)

    request =
      %{"code" => code}
      |> put_if("contextId", context_id(opts[:context]))
      |> put_if("envs", opts[:env])
      |> put_if("timeout", opts[:timeout])

    ws_mod = ExDaytona.Client.transport(sandbox.client, :websocket)

    with {:ok, base_url} <- toolbox_base_url(sandbox),
         {:ok, ws} <-
           ws_mod.connect(
             base_url <> "/process/interpreter/execute",
             sandbox.client.api_key,
             []
           ),
         :ok <- ws_mod.send_text(ws, JSON.encode!(request)) do
      collect(ws_mod, ws, %{stdout: "", stderr: "", error: nil}, opts, receive_timeout)
    end
  end

  @doc """
  Create an isolated interpreter context. Options: `:cwd`.
  """
  @spec create_context(Sandbox.t(), keyword()) ::
          {:ok, Model.InterpreterContext.t()} | {:error, Error.t()}
  def create_context(%Sandbox{} = sandbox, opts \\ []) do
    request = %Model.CreateContextRequest{cwd: opts[:cwd], language: "python"}

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox) do
      Error.normalize(Api.Interpreter.create_interpreter_context(conn, request))
    end
  end

  @doc """
  List the sandbox's interpreter contexts.
  """
  @spec list_contexts(Sandbox.t()) ::
          {:ok, [Model.InterpreterContext.t()]} | {:error, Error.t()}
  def list_contexts(%Sandbox{} = sandbox) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, %Model.ListContextsResponse{contexts: contexts}} <-
           Error.normalize(Api.Interpreter.list_interpreter_contexts(conn)) do
      {:ok, contexts || []}
    end
  end

  @doc """
  Delete an interpreter context (by struct or id). Returns `:ok`.
  """
  @spec delete_context(Sandbox.t(), Model.InterpreterContext.t() | String.t()) ::
          :ok | {:error, Error.t()}
  def delete_context(%Sandbox{} = sandbox, context) do
    id = context_id(context)

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, _} <- Error.normalize(Api.Interpreter.delete_interpreter_context(conn, id)) do
      :ok
    end
  end

  ## Internals ---------------------------------------------------------------

  defp collect(ws_mod, ws, result, opts, timeout) do
    receive do
      {:ex_daytona_ws, ^ws, {frame_type, data}} when frame_type in [:text, :binary] ->
        case JSON.decode(data) do
          {:ok, chunk} -> collect(ws_mod, ws, apply_chunk(chunk, result, opts), opts, timeout)
          {:error, _} -> collect(ws_mod, ws, result, opts, timeout)
        end

      {:ex_daytona_ws, ^ws, {:closed, _reason}} ->
        {:ok, result}
    after
      timeout ->
        ws_mod.close(ws)
        {:error, %Error{message: "interpreter run timed out after #{timeout}ms", details: result}}
    end
  end

  defp apply_chunk(%{"type" => "stdout"} = chunk, result, opts) do
    text = Map.get(chunk, "text", "")
    if fun = opts[:on_stdout], do: fun.(text)
    %{result | stdout: result.stdout <> text}
  end

  defp apply_chunk(%{"type" => "stderr"} = chunk, result, opts) do
    text = Map.get(chunk, "text", "")
    if fun = opts[:on_stderr], do: fun.(text)
    %{result | stderr: result.stderr <> text}
  end

  defp apply_chunk(%{"type" => "error"} = chunk, result, opts) do
    error = %{
      name: Map.get(chunk, "name", ""),
      value: Map.get(chunk, "value", ""),
      traceback: Map.get(chunk, "traceback", "")
    }

    if fun = opts[:on_error], do: fun.(error)
    %{result | error: error}
  end

  defp apply_chunk(_chunk, result, _opts), do: result

  defp context_id(nil), do: nil
  defp context_id(%Model.InterpreterContext{id: id}), do: id
  defp context_id(id) when is_binary(id), do: id

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp toolbox_base_url(%Sandbox{info: info}) do
    {:ok, Toolbox.base_url(info)}
  rescue
    e in ArgumentError -> {:error, %Error{message: Exception.message(e), details: e}}
  end
end
