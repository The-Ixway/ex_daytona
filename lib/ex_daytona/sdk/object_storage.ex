defmodule ExDaytona.ObjectStorage do
  @moduledoc """
  Build-context uploads for declarative image builds.

  When an `ExDaytona.Image` includes local files (`add_local_file/3`,
  `add_local_dir/3`), the files are packaged as tars and pushed to
  Daytona's S3-compatible object storage before the build; the build
  references them by content hash (`contextHashes`). This module
  implements that flow — `ExDaytona.Sandbox.create/2` calls it
  automatically, so it is rarely used directly.

  The upload speaks S3 (SigV4) via the SDK's own HTTP stack — no AWS
  dependency.
  """

  alias ExDaytona.Api
  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.SigV4

  @doc """
  Temporary push credentials for the organization's build-context
  storage, as a snake_case map.
  """
  @spec push_access(Client.t()) ::
          {:ok,
           %{
             access_key: String.t(),
             secret: String.t(),
             session_token: String.t() | nil,
             bucket: String.t(),
             storage_url: String.t(),
             region: String.t() | nil,
             organization_id: String.t()
           }}
          | {:error, Error.t()}
  def push_access(%Client{} = client) do
    with {:ok, %Model.StorageAccessDto{} = dto} <-
           Error.normalize(Api.ObjectStorage.get_push_access(client.conn)) do
      {:ok,
       %{
         access_key: dto.accessKey,
         secret: dto.secret,
         session_token: dto.sessionToken,
         bucket: dto.bucket,
         storage_url: dto.storageUrl,
         region: dto.region,
         organization_id: dto.organizationId
       }}
    end
  end

  @doc """
  Upload one build context (a file or directory) and return its hash.

  Skips the upload when an object with the same content hash already
  exists. `archive_path` defaults to `archive_base_path(source_path)`.
  """
  @spec upload_context(Client.t(), Path.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def upload_context(%Client{} = client, source_path, opts \\ []) do
    with {:ok, access} <- push_access(client) do
      upload_context_with_access(access, source_path, opts)
    end
  end

  @doc """
  Like `upload_context/3` but reuses already-fetched push credentials —
  used to upload several contexts under one credential grant.
  """
  @spec upload_context_with_access(map(), Path.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def upload_context_with_access(access, source_path, opts \\ []) do
    archive_path = Keyword.get(opts, :archive_path, archive_base_path(source_path))

    if File.exists?(source_path) do
      ensure_uploaded(access, source_path, archive_path)
    else
      {:error, %Error{message: "build context does not exist: #{source_path}"}}
    end
  end

  defp ensure_uploaded(access, source_path, archive_path) do
    hash = hash_path(source_path, archive_path)
    key = "#{access.organization_id}/#{hash}/context.tar"

    if object_exists?(access, key) do
      {:ok, hash}
    else
      with {:ok, tar} <- build_tar(source_path, archive_path),
           :ok <- put_object(access, key, tar) do
        {:ok, hash}
      end
    end
  end

  @doc """
  The archive path for a local path: normalized, without the leading
  separator — used as the tar entry name, the content-hash salt, and the
  `COPY` source in the generated Dockerfile.
  """
  @spec archive_base_path(Path.t()) :: String.t()
  def archive_base_path(path) do
    case path |> to_string() |> Path.split() |> Enum.reject(&(&1 in ["/", "."])) do
      [] -> ""
      segments -> Path.join(segments)
    end
  end

  @doc false
  # MD5 over the archive path and the content (file bytes; for
  # directories, each entry's relative path then bytes, sorted for
  # determinism). Content-addresses the context.tar in object storage.
  def hash_path(source_path, archive_path) do
    hasher = :crypto.hash_init(:md5)
    hasher = :crypto.hash_update(hasher, archive_path)

    hasher =
      if File.dir?(source_path) do
        hash_dir(hasher, source_path, source_path)
      else
        hash_file_content(hasher, source_path)
      end

    hasher |> :crypto.hash_final() |> Base.encode16(case: :lower)
  end

  defp hash_dir(hasher, root, dir) do
    entries = dir |> File.ls!() |> Enum.sort()

    if entries == [] and dir != root do
      :crypto.hash_update(hasher, Path.relative_to(dir, root))
    else
      Enum.reduce(entries, hasher, &hash_entry(&2, root, Path.join(dir, &1)))
    end
  end

  defp hash_entry(hasher, root, path) do
    if File.dir?(path) do
      hash_dir(hasher, root, path)
    else
      hasher
      |> :crypto.hash_update(Path.relative_to(path, root))
      |> hash_file_content(path)
    end
  end

  defp hash_file_content(hasher, path) do
    path
    |> File.stream!(64 * 1024)
    |> Enum.reduce(hasher, &:crypto.hash_update(&2, &1))
  end

  defp build_tar(source_path, archive_path) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ex_daytona_context_#{System.unique_integer([:positive])}.tar"
      )

    try do
      case :erl_tar.create(
             String.to_charlist(tmp),
             [{String.to_charlist(archive_path), String.to_charlist(to_string(source_path))}],
             []
           ) do
        :ok -> {:ok, File.read!(tmp)}
        {:error, reason} -> {:error, %Error{message: "tar failed: #{inspect(reason)}"}}
      end
    after
      File.rm(tmp)
    end
  end

  defp object_exists?(access, key) do
    case s3_request(access, "HEAD", key, "") do
      {:ok, %Finch.Response{status: 200}} -> true
      _ -> false
    end
  end

  defp put_object(access, key, body) do
    case s3_request(access, "PUT", key, body) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error,
         %Error{
           status: status,
           message: "build context upload failed (HTTP #{status})",
           details: resp_body
         }}

      {:error, reason} ->
        {:error, Error.from(reason)}
    end
  end

  defp s3_request(access, method, key, body) do
    uri =
      access.storage_url
      |> URI.parse()
      |> then(fn uri -> %{uri | path: "/#{access.bucket}/#{key}"} end)

    creds = %{
      access_key: access.access_key,
      secret: access.secret,
      session_token: access.session_token,
      region: access.region || "us-east-1"
    }

    headers = SigV4.sign(method, uri, body, creds, DateTime.utc_now())

    method
    |> Finch.build(URI.to_string(uri), headers, if(body == "", do: nil, else: body))
    |> Finch.request(ExDaytona.Finch, receive_timeout: 120_000)
  end
end
