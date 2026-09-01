defmodule ExDaytona.FS.Stream do
  @moduledoc false
  # Internal engine for ExDaytona.FS's constant-memory transfer functions.
  #
  # NOTE: upload progress/abort assume the request body stream is consumed
  # in the calling process — true for the default Finch HTTP/1 pools and
  # for in-process test transports.
  # Uploads hand-frame multipart around a lazy Enumerable and send it as a
  # streamed request body; downloads fold over response chunks. Both run
  # through the client's configured ExDaytona.Transport.HTTPStream
  # implementation (the dedicated stream pool by default) and support
  # max-bytes limits, idle/overall timeouts, caller cancellation, and
  # incremental SHA-256.

  alias ExDaytona.Error
  alias ExDaytona.HTTPStream
  alias ExDaytona.Redact
  alias ExDaytona.Toolbox

  @default_chunk_size 64 * 1024
  @max_error_body_bytes 65_536

  ## Upload -------------------------------------------------------------------

  @doc false
  def upload(sandbox, remote_path, source, opts) do
    transport = ExDaytona.Client.transport(sandbox.client, :http_stream)
    max_bytes = Keyword.get(opts, :max_bytes, :infinity)
    deadline = HTTPStream.deadline_at(Keyword.get(opts, :deadline, :infinity))
    cancel = Keyword.get(opts, :cancel)
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

    with {:ok, base_url} <- toolbox_base_url(sandbox),
         {:ok, data_stream} <- normalize_source(source, chunk_size) do
      boundary = "ex-daytona-#{System.unique_integer([:positive])}-#{:erlang.unique_integer([:positive])}"
      filename = Path.basename(remote_path)

      prelude =
        ~s(--#{boundary}\r\n) <>
          ~s(Content-Disposition: form-data; name="file"; filename="#{filename}"\r\n) <>
          ~s(Content-Type: application/octet-stream\r\n\r\n)

      trailer = "\r\n--#{boundary}--\r\n"

      progress = start_progress()

      limits = %{deadline: deadline, max_bytes: max_bytes, cancel: cancel, progress: progress}

      guarded =
        Stream.transform(
          data_stream,
          {0, :crypto.hash_init(:sha256)},
          &guard_chunk(&1, &2, limits)
        )

      body = Stream.concat([[prelude], guarded, [trailer]])

      url =
        base_url <>
          "/files/upload-v2?path=" <> URI.encode_www_form(remote_path)

      headers = [
        {"authorization", "Bearer " <> sandbox.client.api_key},
        {"content-type", "multipart/form-data; boundary=#{boundary}"}
      ]

      result =
        try do
          transport.stream(
            "POST",
            url,
            headers,
            {:stream, body},
            {nil, []},
            fn
              {:status, status}, {_s, b} -> {:cont, {status, b}}
              {:headers, _h}, acc -> {:cont, acc}
              {:data, chunk}, {s, b} -> {:cont, {s, bounded_append(b, chunk)}}
            end,
            [receive_timeout: Keyword.get(opts, :idle_timeout, 120_000)] ++
              Keyword.take(opts, [:pool])
          )
        catch
          {:ex_daytona_upload_abort, reason} -> {:aborted, reason}
        end

      finish_upload(result, progress, opts)
    end
  end

  defp guard_chunk(chunk, {bytes, sha}, limits) do
    chunk = IO.iodata_to_binary(chunk)
    bytes = bytes + byte_size(chunk)

    cond do
      HTTPStream.past?(limits.deadline) ->
        throw({:ex_daytona_upload_abort, :deadline})

      limits.max_bytes != :infinity and bytes > limits.max_bytes ->
        throw({:ex_daytona_upload_abort, :max_bytes})

      is_function(limits.cancel, 0) and limits.cancel.() ->
        throw({:ex_daytona_upload_abort, :canceled})

      true ->
        sha = :crypto.hash_update(sha, chunk)
        record_progress(limits.progress, bytes, sha)
        {[chunk], {bytes, sha}}
    end
  end

  defp finish_upload({:aborted, :deadline}, progress, _opts) do
    clear_progress(progress)
    {:error, %Error{message: "upload exceeded its overall deadline"}}
  end

  defp finish_upload({:aborted, :max_bytes}, progress, _opts) do
    clear_progress(progress)
    {:error, %Error{message: "upload exceeded max_bytes; request aborted"}}
  end

  defp finish_upload({:aborted, :canceled}, progress, _opts) do
    clear_progress(progress)
    {:error, %Error{message: "upload canceled by caller"}}
  end

  defp finish_upload({:ok, {status, _body}}, progress, opts) when status in 200..299 do
    {bytes, sha_hex} = read_progress(progress)

    case Keyword.get(opts, :expected_sha256) do
      nil ->
        {:ok, %{bytes: bytes, sha256: sha_hex}}

      expected ->
        if String.downcase(expected) == sha_hex do
          {:ok, %{bytes: bytes, sha256: sha_hex}}
        else
          {:error,
           %Error{
             message: "upload checksum mismatch: expected #{Redact.marker()}, sent #{sha_hex}"
           }}
        end
    end
  end

  defp finish_upload({:ok, {status, error_body}}, progress, _opts) do
    clear_progress(progress)
    body = error_body |> IO.iodata_to_binary() |> decode_json_maybe()
    {:error, Error.from(%Tesla.Env{status: status, body: body})}
  end

  defp finish_upload({:error, reason, _acc}, progress, _opts) do
    clear_progress(progress)
    {:error, Error.from(reason)}
  end

  ## Download -----------------------------------------------------------------

  @doc false
  def download(sandbox, remote_path, consumer, opts) when is_function(consumer, 1) do
    transport = ExDaytona.Client.transport(sandbox.client, :http_stream)
    max_bytes = Keyword.get(opts, :max_bytes, :infinity)
    deadline = HTTPStream.deadline_at(Keyword.get(opts, :deadline, :infinity))

    with {:ok, base_url} <- toolbox_base_url(sandbox) do
      url = base_url <> "/files/download?path=" <> URI.encode_www_form(remote_path)

      headers = [
        {"authorization", "Bearer " <> sandbox.client.api_key},
        {"accept", "application/octet-stream"}
      ]

      init = %{
        status: nil,
        error_body: [],
        bytes: 0,
        sha: :crypto.hash_init(:sha256),
        stop: nil
      }

      result =
        transport.stream(
          "GET",
          url,
          headers,
          nil,
          init,
          &download_event(&1, &2, consumer, max_bytes, deadline),
          [receive_timeout: Keyword.get(opts, :idle_timeout, 120_000)] ++
            Keyword.take(opts, [:pool])
        )

      finish_download(result, opts)
    end
  end

  defp download_event({:status, status}, acc, _consumer, _max, _deadline),
    do: {:cont, %{acc | status: status}}

  defp download_event({:headers, _}, acc, _consumer, _max, _deadline), do: {:cont, acc}

  defp download_event({:data, chunk}, %{status: status} = acc, _c, _max, _deadline)
       when status >= 400 do
    {:cont, %{acc | error_body: bounded_append(acc.error_body, chunk)}}
  end

  defp download_event({:data, chunk}, acc, consumer, max_bytes, deadline) do
    bytes = acc.bytes + byte_size(chunk)

    cond do
      HTTPStream.past?(deadline) ->
        {:halt, %{acc | stop: :deadline}}

      max_bytes != :infinity and bytes > max_bytes ->
        {:halt, %{acc | stop: :max_bytes}}

      true ->
        case consumer.(chunk) do
          :halt ->
            {:halt, %{acc | stop: :canceled}}

          _ ->
            {:cont, %{acc | bytes: bytes, sha: :crypto.hash_update(acc.sha, chunk)}}
        end
    end
  end

  defp finish_download({:ok, %{stop: :deadline}}, _opts),
    do: {:error, %Error{message: "download exceeded its overall deadline"}}

  defp finish_download({:ok, %{stop: :max_bytes}}, _opts),
    do: {:error, %Error{message: "download exceeded max_bytes; request aborted"}}

  defp finish_download({:ok, %{stop: :canceled}}, _opts),
    do: {:error, %Error{message: "download canceled by consumer"}}

  defp finish_download({:ok, %{status: status} = acc}, opts) when status in 200..299 do
    sha_hex = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)

    case Keyword.get(opts, :expected_sha256) do
      nil ->
        {:ok, %{bytes: acc.bytes, sha256: sha_hex}}

      expected ->
        if String.downcase(expected) == sha_hex do
          {:ok, %{bytes: acc.bytes, sha256: sha_hex}}
        else
          {:error, %Error{message: "download checksum mismatch (got #{sha_hex})", code: "CHECKSUM_MISMATCH"}}
        end
    end
  end

  defp finish_download({:ok, %{status: status, error_body: error_body}}, _opts) do
    body = error_body |> IO.iodata_to_binary() |> decode_json_maybe()
    {:error, Error.from(%Tesla.Env{status: status, body: body})}
  end

  defp finish_download({:error, reason, _acc}, _opts), do: {:error, Error.from(reason)}

  ## Shared -------------------------------------------------------------------

  @doc false
  def normalize_source({:file, path}, chunk_size) do
    if File.regular?(path) do
      {:ok, File.stream!(path, chunk_size)}
    else
      {:error, %Error{message: "not a regular file: #{path}"}}
    end
  end

  def normalize_source(device, chunk_size) when is_pid(device) or is_atom(device) do
    {:ok, IO.binstream(device, chunk_size)}
  end

  def normalize_source(enumerable, _chunk_size) do
    if Enumerable.impl_for(enumerable) do
      {:ok, enumerable}
    else
      {:error, %Error{message: "upload source is not an Enumerable, IO device, or {:file, path}"}}
    end
  end

  defp toolbox_base_url(%ExDaytona.Sandbox{info: info}) do
    {:ok, Toolbox.base_url(info)}
  rescue
    e in ArgumentError -> {:error, %Error{message: Exception.message(e), details: e}}
  end

  defp bounded_append(iodata, chunk) do
    if IO.iodata_length(iodata) >= @max_error_body_bytes, do: iodata, else: [iodata, chunk]
  end

  defp decode_json_maybe(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  # The upload byte/sha progress lives in the process dictionary because the
  # Stream.transform accumulator is not observable after the transport
  # consumes the stream (Finch runs the request in the calling process, so
  # the pdict is shared with the enumeration).
  defp start_progress do
    key = {:ex_daytona_upload_progress, make_ref()}
    Process.put(key, {0, nil})
    key
  end

  defp record_progress(key, bytes, sha), do: Process.put(key, {bytes, sha})

  defp read_progress(key) do
    {bytes, sha} = Process.get(key, {0, nil})
    Process.delete(key)

    sha_hex =
      case sha do
        nil -> :crypto.hash_init(:sha256) |> :crypto.hash_final() |> Base.encode16(case: :lower)
        ctx -> ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
      end

    {bytes, sha_hex}
  end

  defp clear_progress(key), do: Process.delete(key)
end
