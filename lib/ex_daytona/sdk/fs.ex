defmodule ExDaytona.FS do
  @moduledoc """
  File-system operations inside a sandbox.

  The full facade over the toolbox file-system API — writing/reading,
  directories, metadata, permissions, search, and text replacement:

      :ok = ExDaytona.FS.mkdir(sandbox, "/workspace/data")
      :ok = ExDaytona.FS.write_file(sandbox, "/workspace/data/hello.txt", "hi")
      {:ok, "hi"} = ExDaytona.FS.read_file(sandbox, "/workspace/data/hello.txt")

      {:ok, files} = ExDaytona.FS.list_files(sandbox, "/workspace/data")
      {:ok, %ExDaytona.Model.FileInfo{}} = ExDaytona.FS.stat(sandbox, "/workspace/data/hello.txt")

      {:ok, paths} = ExDaytona.FS.search(sandbox, "/workspace", "*.txt")     # glob on names
      {:ok, matches} = ExDaytona.FS.grep(sandbox, "/workspace", "TODO")      # text in contents

      :ok = ExDaytona.FS.move(sandbox, "/workspace/data/hello.txt", "/workspace/hello.txt")
      :ok = ExDaytona.FS.delete(sandbox, "/workspace/data", recursive: true)

  `ExDaytona.Sandbox.write_file/3`, `read_file/2`, and `list_files/2`
  delegate here — use whichever module reads better at the call site.
  """

  alias ExDaytona.Api
  alias ExDaytona.Connection
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Sandbox

  ## Content ------------------------------------------------------------------

  @doc """
  Write `content` to `path` inside the sandbox (parent directories are
  created by the API). Returns `:ok`.
  """
  @spec write_file(Sandbox.t(), String.t(), iodata()) :: :ok | {:error, Error.t()}
  def write_file(%Sandbox{} = sandbox, path, content) when is_binary(path) do
    multipart =
      Tesla.Multipart.new()
      |> Tesla.Multipart.add_file_content(IO.iodata_to_binary(content), Path.basename(path), name: "file")

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
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
  Read the file at `path`. Returns `{:ok, binary}`.
  """
  @spec read_file(Sandbox.t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read_file(%Sandbox{} = sandbox, path) when is_binary(path) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, %Tesla.Env{body: body}} <-
           Error.normalize(Api.FileSystem.download_file(conn, path)) do
      {:ok, body}
    end
  end

  @doc """
  Upload a local file to `remote_path` inside the sandbox.
  """
  @spec upload(Sandbox.t(), Path.t(), String.t()) :: :ok | {:error, Error.t()}
  def upload(%Sandbox{} = sandbox, local_path, remote_path) when is_binary(remote_path) do
    case File.read(local_path) do
      {:ok, content} ->
        write_file(sandbox, remote_path, content)

      {:error, reason} ->
        {:error, %Error{message: "cannot read #{local_path}: #{:file.format_error(reason)}"}}
    end
  end

  @doc """
  Download the file at `remote_path` to a local path.
  """
  @spec download(Sandbox.t(), String.t(), Path.t()) :: :ok | {:error, Error.t()}
  def download(%Sandbox{} = sandbox, remote_path, local_path) when is_binary(remote_path) do
    with {:ok, content} <- read_file(sandbox, remote_path) do
      case File.write(local_path, content) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, %Error{message: "cannot write #{local_path}: #{:file.format_error(reason)}"}}
      end
    end
  end

  @doc """
  Write several files in one call: `entries` is a list of
  `{path, content}` tuples. Stops at the first failure.
  """
  @spec write_files(Sandbox.t(), [{String.t(), iodata()}]) :: :ok | {:error, Error.t()}
  def write_files(%Sandbox{} = sandbox, entries) when is_list(entries) do
    Enum.reduce_while(entries, :ok, fn {path, content}, :ok ->
      case write_file(sandbox, path, content) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  ## Directories & metadata ---------------------------------------------------

  @doc """
  List files at `path` (default: the working directory). Returns
  `{:ok, [%ExDaytona.Model.FileInfo{}]}`.
  """
  @spec list_files(Sandbox.t(), String.t() | nil) ::
          {:ok, [Model.FileInfo.t()]} | {:error, Error.t()}
  def list_files(%Sandbox{} = sandbox, path \\ nil) do
    opts = if path, do: [path: path], else: []

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, files} <- Error.normalize(Api.FileSystem.list_files(conn, opts)) do
      {:ok, List.wrap(files)}
    end
  end

  @doc """
  Create a directory (and parents) at `path`.

  Options: `:mode` — permission string (default `"755"`).
  """
  @spec mkdir(Sandbox.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def mkdir(%Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    mode = Keyword.get(opts, :mode, "755")

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, _} <- Error.normalize(Api.FileSystem.create_folder(conn, path, mode)) do
      :ok
    end
  end

  @doc """
  File metadata for `path` as an `ExDaytona.Model.FileInfo`.
  """
  @spec stat(Sandbox.t(), String.t()) :: {:ok, Model.FileInfo.t()} | {:error, Error.t()}
  def stat(%Sandbox{} = sandbox, path) when is_binary(path) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox) do
      Error.normalize(Api.FileSystem.get_file_info(conn, path))
    end
  end

  @doc """
  Delete the file or directory at `path`.

  Options: `:recursive` — required to delete non-empty directories.
  """
  @spec delete(Sandbox.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(%Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    api_opts = if Keyword.get(opts, :recursive), do: [recursive: true], else: []

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, _} <- Error.normalize(Api.FileSystem.delete_file(conn, path, api_opts)) do
      :ok
    end
  end

  @doc """
  Move (or rename) `source` to `destination`.
  """
  @spec move(Sandbox.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def move(%Sandbox{} = sandbox, source, destination)
      when is_binary(source) and is_binary(destination) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, _} <- Error.normalize(Api.FileSystem.move_file(conn, source, destination)) do
      :ok
    end
  end

  @doc """
  Set permissions/ownership on `path`.

  Options: `:mode` (e.g. `"644"`), `:owner`, `:group` — at least one is
  required.
  """
  @spec chmod(Sandbox.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def chmod(%Sandbox{} = sandbox, path, opts) when is_binary(path) and opts != [] do
    api_opts = Keyword.take(opts, [:mode, :owner, :group])

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, _} <- Error.normalize(Api.FileSystem.set_file_permissions(conn, path, api_opts)) do
      :ok
    end
  end

  ## Search & replace ---------------------------------------------------------

  @doc """
  Find files under `path` whose names match the glob `pattern`.
  Returns `{:ok, [path]}`.
  """
  @spec search(Sandbox.t(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, Error.t()}
  def search(%Sandbox{} = sandbox, path, pattern)
      when is_binary(path) and is_binary(pattern) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, %Model.SearchFilesResponse{files: files}} <-
           Error.normalize(Api.FileSystem.search_files(conn, path, pattern)) do
      {:ok, files || []}
    end
  end

  @doc """
  Search file *contents* under `path` for `pattern`. Returns
  `{:ok, [%ExDaytona.Model.Match{file, line, content}]}`.
  """
  @spec grep(Sandbox.t(), String.t(), String.t()) ::
          {:ok, [Model.Match.t()]} | {:error, Error.t()}
  def grep(%Sandbox{} = sandbox, path, pattern)
      when is_binary(path) and is_binary(pattern) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, matches} <- Error.normalize(Api.FileSystem.find_in_files(conn, path, pattern)) do
      {:ok, List.wrap(matches)}
    end
  end

  @doc """
  Replace `pattern` with `replacement` across `files`. Returns
  `{:ok, [%ExDaytona.Model.ReplaceResult{file, success, error}]}` — a
  per-file report, not all-or-nothing.
  """
  @spec replace(Sandbox.t(), [String.t()], String.t(), String.t()) ::
          {:ok, [Model.ReplaceResult.t()]} | {:error, Error.t()}
  def replace(%Sandbox{} = sandbox, files, pattern, replacement)
      when is_list(files) and is_binary(pattern) and is_binary(replacement) do
    request = %Model.ReplaceRequest{files: files, pattern: pattern, newValue: replacement}

    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, results} <- Error.normalize(Api.FileSystem.replace_in_files(conn, request)) do
      {:ok, List.wrap(results)}
    end
  end
end
