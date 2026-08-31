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
  - `:image` — build the sandbox declaratively instead of from a snapshot:
    an `ExDaytona.Image` or a raw Dockerfile string. Building takes longer
    than starting from a snapshot — raise `:timeout` accordingly and watch
    progress with `stream_build_logs/3`.
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
    {image, opts} = Keyword.pop(opts, :image)

    with {:ok, model} <- build_create_model(opts),
         {:ok, model} <- apply_image(model, image, client),
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

  ## SSH access --------------------------------------------------------------

  @doc """
  Create SSH access to the sandbox. Returns
  `{:ok, %{token, ssh_command, expires_at}}` — run `ssh_command` in a
  terminal, or use `token` as the SSH username against Daytona's SSH
  gateway.

  Options: `:expires_in_minutes` — token lifetime (server default when
  omitted).
  """
  @spec ssh_access(t(), keyword()) ::
          {:ok, %{token: String.t(), ssh_command: String.t() | nil, expires_at: String.t() | nil}}
          | {:error, Error.t()}
  def ssh_access(%__MODULE__{client: client, info: %{id: id}}, opts \\ []) do
    api_opts =
      case Keyword.fetch(opts, :expires_in_minutes) do
        {:ok, minutes} -> [expiresInMinutes: minutes]
        :error -> []
      end

    with {:ok, %Model.SshAccessDto{} = dto} <-
           Error.normalize(Api.Sandbox.create_ssh_access(client.conn, id, api_opts)) do
      {:ok, %{token: dto.token, ssh_command: dto.sshCommand, expires_at: dto.expiresAt}}
    end
  end

  @doc """
  Revoke the sandbox's SSH access. Returns `:ok`.
  """
  @spec revoke_ssh_access(t()) :: :ok | {:error, Error.t()}
  def revoke_ssh_access(%__MODULE__{client: client, info: %{id: id}}) do
    with {:ok, _} <- Error.normalize(Api.Sandbox.revoke_ssh_access(client.conn, id)), do: :ok
  end

  @doc """
  Validate an SSH access token (for building SSH gateways/tooling).
  Returns `{:ok, %{valid: boolean, sandbox_id: id | nil}}`.

  > #### Authentication {: .warning}
  >
  > This endpoint authenticates gateway infrastructure — with a regular
  > user API key it returns `403 "Invalid authentication context"`.
  """
  @spec validate_ssh_access(Client.t(), String.t()) ::
          {:ok, %{valid: boolean() | nil, sandbox_id: String.t() | nil}} | {:error, Error.t()}
  def validate_ssh_access(%Client{} = client, token) when is_binary(token) do
    with {:ok, %Model.SshAccessValidationDto{valid: valid, sandboxId: sandbox_id}} <-
           Error.normalize(Api.Sandbox.validate_ssh_access(client.conn, token)) do
      {:ok, %{valid: valid, sandbox_id: sandbox_id}}
    end
  end

  ## Preview URLs -------------------------------------------------------------

  @doc """
  The preview URL for a port the sandbox is listening on. Returns
  `{:ok, %{url, token}}` — for private sandboxes, send the token as the
  `x-daytona-preview-token` header (browsers hitting the URL directly get
  Daytona's auth flow).
  """
  @spec preview_url(t(), pos_integer()) ::
          {:ok, %{url: String.t(), token: String.t() | nil}} | {:error, Error.t()}
  def preview_url(%__MODULE__{client: client, info: %{id: id}}, port) when is_integer(port) do
    with {:ok, %Model.PortPreviewUrl{url: url, token: token}} <-
           Error.normalize(Api.Sandbox.get_port_preview_url(client.conn, id, port)) do
      {:ok, %{url: url, token: token}}
    end
  end

  @doc """
  A signed (self-authenticating, expiring) preview URL for a port —
  shareable without exposing an auth token header. Returns
  `{:ok, %{url, token}}`; expire it early with
  `expire_signed_preview_url/3`.

  Options: `:expires_in_seconds` — link lifetime (server default when
  omitted).
  """
  @spec signed_preview_url(t(), pos_integer(), keyword()) ::
          {:ok, %{url: String.t(), token: String.t() | nil}} | {:error, Error.t()}
  def signed_preview_url(%__MODULE__{client: client, info: %{id: id}}, port, opts \\ [])
      when is_integer(port) do
    api_opts =
      case Keyword.fetch(opts, :expires_in_seconds) do
        {:ok, seconds} -> [expiresInSeconds: seconds]
        :error -> []
      end

    with {:ok, %Model.SignedPortPreviewUrl{url: url, token: token}} <-
           Error.normalize(Api.Sandbox.get_signed_port_preview_url(client.conn, id, port, api_opts)) do
      {:ok, %{url: url, token: token}}
    end
  end

  @doc """
  Expire a signed preview URL before its natural expiry. Returns `:ok`.
  """
  @spec expire_signed_preview_url(t(), pos_integer(), String.t()) :: :ok | {:error, Error.t()}
  def expire_signed_preview_url(%__MODULE__{client: client, info: %{id: id}}, port, token)
      when is_integer(port) and is_binary(token) do
    with {:ok, _} <-
           Error.normalize(Api.Sandbox.expire_signed_port_preview_url(client.conn, id, port, token)) do
      :ok
    end
  end

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
  Run a code snippet with a fresh interpreter each time (stateless).
  Python, JavaScript, and TypeScript are supported; for persistent state
  across runs use `ExDaytona.CodeInterpreter`.

  ## Options

  - `:language` — `"python"` | `"javascript"` | `"typescript"` (server
    default when omitted)
  - `:argv` — command-line arguments (list)
  - `:env` — environment variables (map)
  - `:timeout` — execution timeout in seconds (API-side)

  Returns `{:ok, %{exit_code, result, artifacts}}` where `result` is the
  combined output and `artifacts` carries chart captures when present.
  """
  @spec run_code(t(), String.t(), keyword()) ::
          {:ok,
           %{
             exit_code: integer() | nil,
             result: String.t() | nil,
             artifacts: Model.CodeRunArtifacts.t() | nil
           }}
          | {:error, Error.t()}
  def run_code(%__MODULE__{} = sandbox, code, opts \\ []) when is_binary(code) do
    request = %Model.CodeRunRequest{
      code: code,
      language: opts[:language],
      argv: opts[:argv],
      envs: opts[:env],
      timeout: opts[:timeout]
    }

    with {:ok, conn} <- toolbox_conn(sandbox),
         {:ok, %Model.CodeRunResponse{} = response} <-
           Error.normalize(Api.Process.code_run(conn, request)) do
      {:ok, %{exit_code: response.exitCode, result: response.result, artifacts: response.artifacts}}
    end
  end

  @doc """
  Write `content` to `path` inside the sandbox. Delegates to
  `ExDaytona.FS.write_file/3` — see `ExDaytona.FS` for the full
  file-system surface.
  """
  @spec write_file(t(), String.t(), iodata()) :: :ok | {:error, Error.t()}
  def write_file(%__MODULE__{} = sandbox, path, content),
    do: ExDaytona.FS.write_file(sandbox, path, content)

  @doc """
  Read the file at `path` inside the sandbox. Delegates to
  `ExDaytona.FS.read_file/2`.
  """
  @spec read_file(t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read_file(%__MODULE__{} = sandbox, path), do: ExDaytona.FS.read_file(sandbox, path)

  @doc """
  List files at `path` inside the sandbox (default: the working
  directory). Delegates to `ExDaytona.FS.list_files/2`.
  """
  @spec list_files(t(), String.t() | nil) :: {:ok, [Model.FileInfo.t()]} | {:error, Error.t()}
  def list_files(%__MODULE__{} = sandbox, path \\ nil),
    do: ExDaytona.FS.list_files(sandbox, path)

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

  defp apply_image(model, nil, _client), do: {:ok, model}

  defp apply_image(model, image, client) do
    build_info = ExDaytona.Image.build_info(image)

    case ExDaytona.Image.contexts(image) do
      [] ->
        {:ok, %{model | buildInfo: build_info}}

      contexts ->
        # Local build contexts (add_local_file/dir) are uploaded to object
        # storage under one credential grant; the build references them by
        # content hash.
        with {:ok, access} <- ExDaytona.ObjectStorage.push_access(client),
             {:ok, hashes} <- upload_contexts(access, contexts) do
          {:ok, %{model | buildInfo: %{build_info | contextHashes: hashes}}}
        end
    end
  end

  defp upload_contexts(access, contexts) do
    Enum.reduce_while(contexts, {:ok, []}, fn context, {:ok, hashes} ->
      case ExDaytona.ObjectStorage.upload_context_with_access(access, context.source_path,
             archive_path: context.archive_path
           ) do
        {:ok, hash} -> {:cont, {:ok, hashes ++ [hash]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

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
