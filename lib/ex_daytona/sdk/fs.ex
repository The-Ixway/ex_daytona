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

  > #### Buffered {: .info}
  >
  > `content` is held fully in memory — appropriate for small control
  > files. For large payloads use `upload_stream/4` / `upload_file/4`.
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

  > #### Buffered {: .info}
  >
  > The whole file is returned as one binary. For large files use
  > `download_stream/4` / `download_file/4`.
  """
  @spec read_file(Sandbox.t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read_file(%Sandbox{} = sandbox, path) when is_binary(path) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox),
         {:ok, %Tesla.Env{body: body}} <-
           Error.normalize(Api.FileSystem.download_file(conn, path, response: :full)) do
      {:ok, body}
    end
  end

  @doc """
  Upload a local file to `remote_path` inside the sandbox.

  > #### Buffered {: .info}
  >
  > Reads the file fully into memory (`File.read/1`). For large files
  > use `upload_file/4`, which streams with constant memory.
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

  > #### Buffered {: .info}
  >
  > Buffers the whole file in memory before writing. For large files use
  > `download_file/4`, which streams to a temporary file and renames
  > atomically.
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

  ## Streaming transfer (constant memory) ------------------------------------

  @doc """
  Upload from a lazy source without buffering it in memory.

  `source` may be an `Enumerable` of iodata chunks, an IO device
  (pid/atom — read with `IO.binstream/2`), or `{:file, path}` (read with
  `File.stream!/2`; `File.read/1` is never used on this path).

  ## Options

  - `:max_bytes` — abort the request once the source exceeds this size
  - `:idle_timeout` — max ms between response events (default `120_000`)
  - `:deadline` — overall ms budget for the transfer
  - `:cancel` — zero-arity fun checked per chunk; returning `true`
    aborts the request
  - `:expected_sha256` — hex digest to verify the streamed bytes against
  - `:chunk_size` — read size for file/IO sources (default 64 KiB)

  Returns `{:ok, %{bytes: n, sha256: hex}}` — the SHA-256 is computed
  incrementally while streaming.
  """
  @spec upload_stream(Sandbox.t(), String.t(), term(), keyword()) ::
          {:ok, %{bytes: non_neg_integer(), sha256: String.t()}} | {:error, Error.t()}
  def upload_stream(%Sandbox{} = sandbox, remote_path, source, opts \\ [])
      when is_binary(remote_path) do
    ExDaytona.FS.Stream.upload(sandbox, remote_path, source, opts)
  end

  @doc """
  Stream a local file to `remote_path` with constant memory. Equivalent
  to `upload_stream(sandbox, remote_path, {:file, local_path}, opts)`.
  """
  @spec upload_file(Sandbox.t(), Path.t(), String.t(), keyword()) ::
          {:ok, %{bytes: non_neg_integer(), sha256: String.t()}} | {:error, Error.t()}
  def upload_file(%Sandbox{} = sandbox, local_path, remote_path, opts \\ [])
      when is_binary(remote_path) do
    upload_stream(sandbox, remote_path, {:file, to_string(local_path)}, opts)
  end

  @doc """
  Stream a download through `consumer`, chunk by chunk, without buffering
  the file.

  `consumer` receives each binary chunk; returning `:halt` cancels the
  transfer (the HTTP request is closed), any other return continues.

  Options: `:max_bytes`, `:idle_timeout`, `:deadline`,
  `:expected_sha256` — as in `upload_stream/4`.

  Returns `{:ok, %{bytes: n, sha256: hex}}` when the stream completed.
  """
  @spec download_stream(Sandbox.t(), String.t(), (binary() -> any()), keyword()) ::
          {:ok, %{bytes: non_neg_integer(), sha256: String.t()}} | {:error, Error.t()}
  def download_stream(%Sandbox{} = sandbox, remote_path, consumer, opts \\ [])
      when is_binary(remote_path) and is_function(consumer, 1) do
    ExDaytona.FS.Stream.download(sandbox, remote_path, consumer, opts)
  end

  @doc """
  A **lazy `Enumerable`** of the file's chunks — the idiomatic way to
  pipe a sandbox file through `Stream`/`Enum` with constant memory:

      sandbox
      |> ExDaytona.FS.stream!("/workspace/big.log")
      |> Stream.into(File.stream!("local.log"))
      |> Stream.run()

      first_kb =
        sandbox
        |> ExDaytona.FS.stream!("/workspace/big.log", max_bytes: 10_000_000)
        |> Enum.reduce_while(<<>>, fn chunk, acc ->
          if byte_size(acc) >= 1024, do: {:halt, acc}, else: {:cont, acc <> chunk}
        end)

  Nothing is requested until enumeration starts; one chunk is in flight
  at a time, so enumeration speed applies backpressure to the transfer.
  Halting early (`Enum.take/2`, `Stream.take_while/2`, ...) cancels the
  HTTP request. A failed transfer **raises** the `ExDaytona.Error` —
  hence the `!` (for the tuple-returning API use `download_stream/4`).

  Options as in `download_stream/4` (`:max_bytes`, `:idle_timeout`,
  `:deadline`, `:expected_sha256`).
  """
  @spec stream!(Sandbox.t(), String.t(), keyword()) :: Enumerable.t()
  def stream!(%Sandbox{} = sandbox, remote_path, opts \\ []) when is_binary(remote_path) do
    ExDaytona.FS.Stream.lazy_download(sandbox, remote_path, opts)
  end

  @doc """
  Stream a download to a local path safely: chunks are written
  incrementally to a sibling temporary file, which is synced, verified
  (`:expected_sha256`, when given), and atomically renamed over
  `local_path` only on success. A failed, canceled, oversized, or
  checksum-mismatched transfer removes the temporary file and never
  touches an existing `local_path`.

  Options as in `download_stream/4`.
  """
  @spec download_file(Sandbox.t(), String.t(), Path.t(), keyword()) ::
          {:ok, %{bytes: non_neg_integer(), sha256: String.t()}} | {:error, Error.t()}
  def download_file(%Sandbox{} = sandbox, remote_path, local_path, opts \\ [])
      when is_binary(remote_path) do
    local_path = to_string(local_path)
    tmp_path = local_path <> ".ex_daytona.#{System.unique_integer([:positive])}.tmp"

    case File.open(tmp_path, [:write, :raw, :binary]) do
      {:error, reason} ->
        {:error, %Error{message: "cannot open #{tmp_path}: #{:file.format_error(reason)}"}}

      {:ok, io} ->
        result = download_stream(sandbox, remote_path, file_writer(io), opts)
        finalize_download_file(result, io, tmp_path, local_path)
    end
  end

  defp file_writer(io) do
    fn chunk ->
      case :file.write(io, chunk) do
        :ok -> :ok
        {:error, _reason} -> :halt
      end
    end
  end

  defp finalize_download_file({:ok, meta}, io, tmp_path, local_path) do
    with :ok <- sync_close(io),
         :ok <- verify_size(tmp_path, meta.bytes),
         :ok <- File.rename(tmp_path, local_path) do
      {:ok, meta}
    else
      {:error, %Error{} = error} ->
        File.rm(tmp_path)
        {:error, error}

      {:error, reason} ->
        File.rm(tmp_path)
        {:error, %Error{message: "finalizing download failed: #{inspect(reason)}"}}
    end
  end

  defp finalize_download_file({:error, error}, io, tmp_path, _local_path) do
    :file.close(io)
    File.rm(tmp_path)
    {:error, error}
  end

  defp sync_close(io) do
    _ = :file.datasync(io)

    case :file.close(io) do
      :ok -> :ok
      {:error, reason} -> {:error, %Error{message: "close failed: #{:file.format_error(reason)}"}}
    end
  end

  defp verify_size(path, expected_bytes) do
    case File.stat(path) do
      {:ok, %{size: ^expected_bytes}} ->
        :ok

      {:ok, %{size: size}} ->
        {:error, %Error{message: "downloaded size mismatch: wrote #{size}, streamed #{expected_bytes}"}}

      {:error, reason} ->
        {:error, %Error{message: "stat failed: #{:file.format_error(reason)}"}}
    end
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
         {:ok, files} <- Error.normalize(Api.FileSystem.list_files(conn, opts ++ [response: :full])) do
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
         {:ok, _} <- Error.normalize(Api.FileSystem.create_folder(conn, path, mode, response: :full)) do
      :ok
    end
  end

  @doc """
  File metadata for `path` as an `ExDaytona.Model.FileInfo`.
  """
  @spec stat(Sandbox.t(), String.t()) :: {:ok, Model.FileInfo.t()} | {:error, Error.t()}
  def stat(%Sandbox{} = sandbox, path) when is_binary(path) do
    with {:ok, conn} <- Sandbox.toolbox_conn(sandbox) do
      Error.normalize(Api.FileSystem.get_file_info(conn, path, response: :full))
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
         {:ok, _} <- Error.normalize(Api.FileSystem.delete_file(conn, path, api_opts ++ [response: :full])) do
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
         {:ok, _} <- Error.normalize(Api.FileSystem.move_file(conn, source, destination, response: :full)) do
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
         {:ok, _} <- Error.normalize(Api.FileSystem.set_file_permissions(conn, path, api_opts ++ [response: :full])) do
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
           Error.normalize(Api.FileSystem.search_files(conn, path, pattern, response: :full)) do
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
         {:ok, matches} <- Error.normalize(Api.FileSystem.find_in_files(conn, path, pattern, response: :full)) do
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
         {:ok, results} <- Error.normalize(Api.FileSystem.replace_in_files(conn, request, response: :full)) do
      {:ok, List.wrap(results)}
    end
  end
end
