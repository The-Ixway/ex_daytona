defmodule ExDaytona.FSStreamTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.FS
  alias ExDaytona.Model
  alias ExDaytona.Sandbox

  defp build_sandbox(base_url, transports \\ []) do
    {:ok, client} =
      Client.new(
        api_key: "dtn_test",
        base_url: base_url,
        retry: false,
        transports: transports
      )

    %Sandbox{
      client: client,
      info: %Model.Sandbox{
        id: "sb-1",
        state: "started",
        toolboxProxyUrl: base_url <> "/toolbox"
      }
    }
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "ex_daytona_fss_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "upload_stream/4" do
    test "streams multipart chunks end-to-end (real HTTP) and computes the checksum" do
      bypass = MockServer.setup()
      sandbox = build_sandbox(MockServer.url(bypass))

      content = String.duplicate("chunk-of-data-", 10_000)
      expected_sha = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

      MockServer.expect_once(bypass, "POST", "/toolbox/sb-1/files/upload-v2", fn conn ->
        assert URI.decode_query(conn.query_string)["path"] == "/data/big.bin"
        assert [ct] = Plug.Conn.get_req_header(conn, "content-type")
        assert ct =~ "multipart/form-data; boundary="

        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        # the streamed payload arrives inside the multipart framing
        assert body =~ "filename=\"big.bin\""
        assert body =~ String.slice(content, 0, 100)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{name: "big.bin"}))
      end)

      source = content |> :binary.bin_to_list() |> Enum.chunk_every(4096) |> Enum.map(&:binary.list_to_bin/1)

      assert {:ok, %{bytes: bytes, sha256: ^expected_sha}} =
               FS.upload_stream(sandbox, "/data/big.bin", source, expected_sha256: expected_sha)

      assert bytes == byte_size(content)
    end

    test "consumes the producer lazily and halts it at max_bytes" do
      sandbox = build_sandbox("http://fake", http_stream: FakeTransports.HTTPStream)
      FakeTransports.script_http(status: 200)

      {:ok, produced} = Agent.start_link(fn -> 0 end)

      # An infinite producer: only laziness (and the max_bytes abort) keeps
      # this test terminating.
      infinite =
        Stream.repeatedly(fn ->
          Agent.update(produced, &(&1 + 1))
          String.duplicate("x", 1024)
        end)

      assert {:error, %Error{message: message}} =
               FS.upload_stream(sandbox, "/data/x.bin", infinite, max_bytes: 10 * 1024)

      assert message =~ "max_bytes"

      # 10KiB limit at 1KiB per element: the producer ran ~11 times, not more
      assert Agent.get(produced, & &1) <= 12
    end

    test "caller cancellation aborts the request" do
      sandbox = build_sandbox("http://fake", http_stream: FakeTransports.HTTPStream)
      FakeTransports.script_http(status: 200)

      {:ok, count} = Agent.start_link(fn -> 0 end)

      cancel = fn -> Agent.get(count, & &1) >= 3 end

      source =
        Stream.repeatedly(fn ->
          Agent.update(count, &(&1 + 1))
          "data"
        end)

      assert {:error, %Error{message: message}} =
               FS.upload_stream(sandbox, "/x", source, cancel: cancel)

      assert message =~ "canceled"
      assert Agent.get(count, & &1) <= 5
    end

    test "upload_file/4 streams from disk without File.read" do
      bypass = MockServer.setup()
      sandbox = build_sandbox(MockServer.url(bypass))
      dir = tmp_dir!()
      local = Path.join(dir, "src.bin")
      File.write!(local, "file-content-here")

      MockServer.expect_once(bypass, "POST", "/toolbox/sb-1/files/upload-v2", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
        assert body =~ "file-content-here"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{}))
      end)

      assert {:ok, %{bytes: 17}} = FS.upload_file(sandbox, local, "/dest.bin")
    end

    test "a non-2xx upload response surfaces as a normalized bounded error" do
      sandbox = build_sandbox("http://fake", http_stream: FakeTransports.HTTPStream)
      big = String.duplicate("e", 200_000)
      FakeTransports.script_http(status: 403, chunks: [big, big])

      assert {:error, %Error{status: 403}} = FS.upload_stream(sandbox, "/x", ["data"])
    end
  end

  describe "download_stream/4" do
    test "delivers chunks incrementally (real chunked HTTP)" do
      bypass = MockServer.setup()
      sandbox = build_sandbox(MockServer.url(bypass))

      MockServer.expect_once(bypass, "GET", "/toolbox/sb-1/files/download", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "part-1|")
        {:ok, conn} = Plug.Conn.chunk(conn, "part-2|")
        {:ok, conn} = Plug.Conn.chunk(conn, "part-3")
        conn
      end)

      {:ok, chunks} = Agent.start_link(fn -> [] end)

      assert {:ok, %{bytes: 20, sha256: sha}} =
               FS.download_stream(sandbox, "/f.bin", fn c ->
                 Agent.update(chunks, &[c | &1])
               end)

      received = chunks |> Agent.get(& &1) |> Enum.reverse()
      assert length(received) >= 2
      assert Enum.join(received) == "part-1|part-2|part-3"
      assert sha == :sha256 |> :crypto.hash("part-1|part-2|part-3") |> Base.encode16(case: :lower)
    end

    test "halts at max_bytes and reports consumer cancellation" do
      sandbox = build_sandbox("http://fake", http_stream: FakeTransports.HTTPStream)

      FakeTransports.script_http(status: 200, chunks: List.duplicate("0123456789", 100))

      assert {:error, %Error{message: message}} =
               FS.download_stream(sandbox, "/f", fn _ -> :ok end, max_bytes: 55)

      assert message =~ "max_bytes"

      FakeTransports.script_http(status: 200, chunks: List.duplicate("0123456789", 100))
      {:ok, seen} = Agent.start_link(fn -> 0 end)

      consumer = fn _chunk ->
        if Agent.get_and_update(seen, &{&1 + 1, &1 + 1}) >= 3, do: :halt, else: :ok
      end

      assert {:error, %Error{message: cancel_message}} =
               FS.download_stream(sandbox, "/f", consumer)

      assert cancel_message =~ "canceled"
      assert Agent.get(seen, & &1) <= 5
    end

    test "idle timeout fires on a stalled stream and deadline on a drip-feed" do
      bypass = MockServer.setup()
      sandbox = build_sandbox(MockServer.url(bypass))

      MockServer.expect_once(bypass, "GET", "/toolbox/sb-1/files/download", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "first")
        Process.sleep(500)
        conn
      end)

      assert {:error, %Error{}} =
               FS.download_stream(sandbox, "/f", fn _ -> :ok end, idle_timeout: 100)

      # Overall deadline with chunks continuously arriving
      sandbox2 = build_sandbox("http://fake", http_stream: FakeTransports.HTTPStream)

      FakeTransports.script_http(
        status: 200,
        chunks: List.duplicate("tick", 100),
        chunk_delay: 5
      )

      assert {:error, %Error{message: message}} =
               FS.download_stream(sandbox2, "/f", fn _ -> :ok end, deadline: 50)

      assert message =~ "deadline"
    end
  end

  describe "download_file/4" do
    test "writes incrementally and atomically renames on success" do
      bypass = MockServer.setup()
      sandbox = build_sandbox(MockServer.url(bypass))
      dir = tmp_dir!()
      dest = Path.join(dir, "out.bin")

      content = "safe-download-content"
      sha = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

      MockServer.expect_once(bypass, "GET", "/toolbox/sb-1/files/download", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.resp(200, content)
      end)

      assert {:ok, %{sha256: ^sha}} =
               FS.download_file(sandbox, "/f.bin", dest, expected_sha256: sha)

      assert File.read!(dest) == content
      # no temp files left behind
      assert dir |> File.ls!() |> Enum.reject(&(&1 == "out.bin")) == []
    end

    test "a failed download never touches an existing destination" do
      sandbox = build_sandbox("http://fake", http_stream: FakeTransports.HTTPStream)
      dir = tmp_dir!()
      dest = Path.join(dir, "keep.bin")
      File.write!(dest, "precious original")

      FakeTransports.script_http(status: 404, chunks: ["nope"])

      assert {:error, %Error{status: 404}} = FS.download_file(sandbox, "/f", dest)

      assert File.read!(dest) == "precious original"
      assert dir |> File.ls!() |> Enum.reject(&(&1 == "keep.bin")) == []
    end

    test "a checksum mismatch removes the temporary result and keeps the destination" do
      sandbox = build_sandbox("http://fake", http_stream: FakeTransports.HTTPStream)
      dir = tmp_dir!()
      dest = Path.join(dir, "target.bin")
      File.write!(dest, "old")

      FakeTransports.script_http(status: 200, chunks: ["tampered content"])

      assert {:error, %Error{code: "CHECKSUM_MISMATCH"}} =
               FS.download_file(sandbox, "/f", dest, expected_sha256: String.duplicate("0", 64))

      assert File.read!(dest) == "old"
      assert dir |> File.ls!() |> Enum.reject(&(&1 == "target.bin")) == []
    end

    test "a partial (transport-failed) download cleans up its temp file" do
      sandbox = build_sandbox("http://fake", http_stream: FakeTransports.HTTPStream)
      dir = tmp_dir!()
      dest = Path.join(dir, "partial.bin")

      FakeTransports.script_http(status: 200, chunks: ["some data"], error: :closed)

      assert {:error, %Error{}} = FS.download_file(sandbox, "/f", dest)

      refute File.exists?(dest)
      assert File.ls!(dir) == []
    end
  end
end
