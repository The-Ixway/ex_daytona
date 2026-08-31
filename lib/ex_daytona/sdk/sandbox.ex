defmodule ExDaytona.Sandbox do
  @moduledoc """
  High-level sandbox facade: lifecycle, command execution, and files.

  Wraps the generated `ExDaytona.Api.Sandbox` (platform) and toolbox APIs
  (`Api.Process`, `Api.FileSystem`) with idiomatic Elixir — snake_case
  options, `{:error, %ExDaytona.Error{}}` failures, and a sandbox struct
  that carries its client so toolbox calls need no extra wiring:

      {:ok, client} = ExDaytona.Client.new()
      {:ok, sandbox} = ExDaytona.Sandbox.create(client, snapshot: "...")

      {:ok, %{exit_code: 0, output: out}} = ExDaytona.Sandbox.exec(sandbox, "echo hello")

      :ok = ExDaytona.Sandbox.write_file(sandbox, "/workspace/hello.txt", "hi")
      {:ok, "hi"} = ExDaytona.Sandbox.read_file(sandbox, "/workspace/hello.txt")

      :ok = ExDaytona.Sandbox.delete(sandbox)

  For sandbox operations the facade doesn't cover, drop down to the
  generated modules with `ExDaytona.Client.conn/1` (platform) or
  `toolbox_conn/1` (toolbox).
  """

  alias ExDaytona.Api
  alias ExDaytona.Client
  alias ExDaytona.Connection
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Toolbox

  @enforce_keys [:client, :info]
  defstruct [:client, :info]

  @typedoc """
  A sandbox bound to the client that created or fetched it.

  `info` is the raw `ExDaytona.Model.Sandbox` (camelCase fields, as sent by
  the API); `id/1` and `state/1` are the ergonomic accessors.
  """
  @type t :: %__MODULE__{client: Client.t(), info: Model.Sandbox.t()}

  # snake_case facade option -> CreateSandbox model field
  @create_fields %{
    snapshot: :snapshot,
    name: :name,
    user: :user,
    cpu: :cpu,
    gpu: :gpu,
    memory: :memory,
    disk: :disk,
    env: :env,
    labels: :labels,
    public: :public,
    target: :target,
    volumes: :volumes,
    ttl_minutes: :ttlMinutes,
    auto_stop_interval: :autoStopInterval,
    auto_archive_interval: :autoArchiveInterval,
    auto_delete_interval: :autoDeleteInterval,
    network_block_all: :networkBlockAll,
    network_allow_list: :networkAllowList
  }

  @error_states ~w(error build_failed destroyed destroying)

  @doc """
  Create a sandbox and (by default) wait for it to reach the `started`
  state.

  ## Options

  - `:wait` — wait until the sandbox is running (default `true`)
  - `:timeout` — max milliseconds to wait (default `120_000`)
  - `:poll_interval` — milliseconds between state polls (default `1_000`)
  - sandbox settings, all optional: `:snapshot`, `:name`, `:user`, `:cpu`,
    `:gpu`, `:memory`, `:disk`, `:env`, `:labels`, `:public`, `:target`,
    `:volumes`, `:ttl_minutes`, `:auto_stop_interval`,
    `:auto_archive_interval`, `:auto_delete_interval`,
    `:network_block_all`, `:network_allow_list`

  With no settings the API uses the organization's default snapshot.
  """
  @spec create(Client.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def create(%Client{} = client, opts \\ []) do
    {wait_opts, opts} = Keyword.split(opts, [:wait, :timeout, :poll_interval])

    with {:ok, model} <- build_create_model(opts),
         {:ok, %Model.Sandbox{} = info} <-
           Error.normalize(Api.Sandbox.create_sandbox(client.conn, model)) do
      sandbox = %__MODULE__{client: client, info: info}

      if Keyword.get(wait_opts, :wait, true) do
        await_state(sandbox, "started", wait_opts)
      else
        {:ok, sandbox}
      end
    end
  end

  @doc """
  Fetch a sandbox by id or name.
  """
  @spec get(Client.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def get(%Client{} = client, id_or_name) when is_binary(id_or_name) do
    with {:ok, %Model.Sandbox{} = info} <-
           Error.normalize(Api.Sandbox.get_sandbox(client.conn, id_or_name)) do
      {:ok, %__MODULE__{client: client, info: info}}
    end
  end

  @doc """
  List sandboxes. Accepts the generated `list_sandboxes` filters
  (`:limit`, `:name`, `:labels`, `:states`, ...) and returns
  `{:ok, %{items: [...], next_cursor: cursor}}` where items are
  `ExDaytona.Model.SandboxListItem` structs.
  """
  @spec list(Client.t(), keyword()) ::
          {:ok, %{items: [Model.SandboxListItem.t()], next_cursor: String.t() | nil}}
          | {:error, Error.t()}
  def list(%Client{} = client, opts \\ []) do
    with {:ok, %Model.ListSandboxesResponse{items: items, nextCursor: cursor}} <-
           Error.normalize(Api.Sandbox.list_sandboxes(client.conn, opts)) do
      {:ok, %{items: items || [], next_cursor: cursor}}
    end
  end

  @doc """
  Re-fetch the sandbox's current state from the API.
  """
  @spec refresh(t()) :: {:ok, t()} | {:error, Error.t()}
  def refresh(%__MODULE__{client: client, info: %{id: id}}), do: get(client, id)

  @doc """
  Start a stopped sandbox. Waits for `started` unless `wait: false`.
  """
  @spec start(t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def start(%__MODULE__{} = sandbox, opts \\ []) do
    lifecycle(sandbox, &Api.Sandbox.start_sandbox/2, "started", opts)
  end

  @doc """
  Stop a running sandbox. Waits for `stopped` unless `wait: false`.
  """
  @spec stop(t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def stop(%__MODULE__{} = sandbox, opts \\ []) do
    lifecycle(sandbox, &Api.Sandbox.stop_sandbox/2, "stopped", opts)
  end

  @doc """
  Delete a sandbox (by struct or id). Returns `:ok`.
  """
  @spec delete(t() | String.t(), Client.t() | nil) :: :ok | {:error, Error.t()}
  def delete(sandbox_or_id, client \\ nil)

  def delete(%__MODULE__{client: client, info: %{id: id}}, _client) do
    with {:ok, _} <- Error.normalize(Api.Sandbox.delete_sandbox(client.conn, id)), do: :ok
  end

  def delete(id, %Client{} = client) when is_binary(id) do
    with {:ok, _} <- Error.normalize(Api.Sandbox.delete_sandbox(client.conn, id)), do: :ok
  end

  @doc """
  Poll until the sandbox reaches `state` (a string or list of strings).

  Fails fast with `{:error, %Error{}}` if the sandbox enters an error state
  (`#{inspect(@error_states)}`), and with a timeout error after `:timeout`
  milliseconds (default `120_000`; poll interval `:poll_interval`, default
  `1_000`).
  """
  @spec await_state(t(), String.t() | [String.t()], keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def await_state(%__MODULE__{} = sandbox, state, opts \\ []) do
    target = List.wrap(state)
    timeout = Keyword.get(opts, :timeout, 120_000)
    interval = Keyword.get(opts, :poll_interval, 1_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_state(sandbox, target, interval, deadline)
  end

  @doc """
  The sandbox id.
  """
  @spec id(t()) :: String.t()
  def id(%__MODULE__{info: %{id: id}}), do: id

  @doc """
  The sandbox state as a string (`"started"`, `"stopped"`, ...).
  """
  @spec state(t()) :: String.t() | nil
  def state(%__MODULE__{info: %{state: state}}), do: state

  @doc """
  The sandbox's build logs so far, as a binary. Only sandboxes built from
  build info have build logs; snapshot-based sandboxes return an error.
  """
  @spec build_logs(t()) :: {:ok, binary()} | {:error, Error.t()}
  def build_logs(%__MODULE__{client: client, info: %{id: id}}) do
    with {:ok, %Tesla.Env{body: body}} <-
           Error.normalize(Api.Sandbox.get_build_logs(client.conn, id)) do
      {:ok, body}
    end
  end

  @doc """
  Follow the sandbox's build logs in real time: `fun` is invoked with
  each chunk as it is produced, and the call returns `:ok` when the build
  finishes and the stream closes.

  Options: `:timeout` — max milliseconds to wait between chunks
  (default `:infinity`).
  """
  @spec stream_build_logs(t(), (binary() -> any()), keyword()) :: :ok | {:error, Error.t()}
  def stream_build_logs(%__MODULE__{client: client, info: %{id: id}}, fun, opts \\ [])
      when is_function(fun, 1) do
    url = Client.base_url(client) <> "/sandbox/#{id}/build-logs?follow=true"

    ExDaytona.HTTPStream.get(url, client.api_key, fun, opts)
  end

  ## Toolbox operations ------------------------------------------------------

  @doc """
  Run a shell command inside the sandbox.

  ## Options

  - `:cwd` — working directory
  - `:env` — extra environment variables (map)
  - `:timeout` — command timeout in seconds (API-side)

  Returns `{:ok, %{exit_code: integer, output: binary}}`.
  """
  @spec exec(t(), String.t(), keyword()) ::
          {:ok, %{exit_code: integer() | nil, output: String.t()}} | {:error, Error.t()}
  def exec(%__MODULE__{} = sandbox, command, opts \\ []) when is_binary(command) do
    request = %Model.ExecuteRequest{
      command: command,
      cwd: opts[:cwd],
      envs: opts[:env],
      timeout: opts[:timeout]
    }

    with {:ok, conn} <- toolbox_conn(sandbox),
         {:ok, %Model.ExecuteResponse{exitCode: code, result: output}} <-
           Error.normalize(Api.Process.execute_command(conn, request)) do
      {:ok, %{exit_code: code, output: output}}
    end
  end

  @doc """
  Write `content` to `path` inside the sandbox (parent directories are
  created by the API). Returns `:ok`.
  """
  @spec write_file(t(), String.t(), iodata()) :: :ok | {:error, Error.t()}
  def write_file(%__MODULE__{} = sandbox, path, content) when is_binary(path) do
    multipart =
      Tesla.Multipart.new()
      |> Tesla.Multipart.add_file_content(IO.iodata_to_binary(content), Path.basename(path), name: "file")

    with {:ok, conn} <- toolbox_conn(sandbox),
         {:ok, _} <-
           Error.normalize(
             Connection.request(conn,
               method: :post,
               url: "/files/upload-v2",
               query: [path: path],
               body: multipart
             )
           ) do
      :ok
    end
  end

  @doc """
  Read the file at `path` inside the sandbox. Returns `{:ok, binary}`.
  """
  @spec read_file(t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read_file(%__MODULE__{} = sandbox, path) when is_binary(path) do
    with {:ok, conn} <- toolbox_conn(sandbox),
         {:ok, %Tesla.Env{body: body}} <-
           Error.normalize(Api.FileSystem.download_file(conn, path)) do
      {:ok, body}
    end
  end

  @doc """
  List files at `path` inside the sandbox (default: the working directory).
  Returns `{:ok, [%ExDaytona.Model.FileInfo{}]}`.
  """
  @spec list_files(t(), String.t() | nil) :: {:ok, [Model.FileInfo.t()]} | {:error, Error.t()}
  def list_files(%__MODULE__{} = sandbox, path \\ nil) do
    opts = if path, do: [path: path], else: []

    with {:ok, conn} <- toolbox_conn(sandbox),
         {:ok, files} <- Error.normalize(Api.FileSystem.list_files(conn, opts)) do
      {:ok, List.wrap(files)}
    end
  end

  @doc """
  The Tesla client for this sandbox's toolbox API, for generated toolbox
  operations the facade doesn't cover (`Api.Git`, `Api.Lsp`,
  `Api.ComputerUse`, ...). Fails if the sandbox has no `toolboxProxyUrl`
  yet (still starting).
  """
  @spec toolbox_conn(t()) :: {:ok, Tesla.Env.client()} | {:error, Error.t()}
  def toolbox_conn(%__MODULE__{client: client, info: info}) do
    {:ok, Toolbox.connection(info, [bearer_token: client.api_key] ++ client.options)}
  rescue
    e in ArgumentError -> {:error, %Error{message: Exception.message(e), details: e}}
  end

  ## Internals ---------------------------------------------------------------

  defp build_create_model(opts) do
    Enum.reduce_while(opts, {:ok, %Model.CreateSandbox{}}, fn {key, value}, {:ok, model} ->
      case Map.fetch(@create_fields, key) do
        {:ok, field} ->
          {:cont, {:ok, Map.put(model, field, value)}}

        :error ->
          {:halt,
           {:error,
            %Error{
              message:
                "unknown sandbox option #{inspect(key)} — supported: " <>
                  (@create_fields |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1))
            }}}
      end
    end)
  end

  defp lifecycle(%__MODULE__{client: client, info: %{id: id}} = sandbox, api_fn, target, opts) do
    with {:ok, %Model.Sandbox{} = info} <- Error.normalize(api_fn.(client.conn, id)) do
      updated = %{sandbox | info: info}

      if Keyword.get(opts, :wait, true) do
        await_state(updated, target, opts)
      else
        {:ok, updated}
      end
    end
  end

  defp poll_state(sandbox, target, interval, deadline) do
    case refresh(sandbox) do
      {:ok, %__MODULE__{info: %{state: state}} = refreshed} ->
        cond do
          state in target ->
            {:ok, refreshed}

          state in @error_states ->
            {:error,
             %Error{
               message:
                 "sandbox #{id(refreshed)} entered state #{inspect(state)}" <>
                   error_reason_suffix(refreshed),
               details: refreshed.info
             }}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error,
             %Error{
               message:
                 "timed out waiting for sandbox #{id(refreshed)} to reach " <>
                   "#{inspect(target)} (still #{inspect(state)})",
               details: refreshed.info
             }}

          true ->
            Process.sleep(interval)
            poll_state(refreshed, target, interval, deadline)
        end

      {:error, _} = error ->
        error
    end
  end

  defp error_reason_suffix(%__MODULE__{info: info}) do
    case Map.get(info, :errorReason) do
      reason when is_binary(reason) and reason != "" -> ": #{reason}"
      _ -> ""
    end
  end
end
