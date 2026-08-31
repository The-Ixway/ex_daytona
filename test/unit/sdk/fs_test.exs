defmodule ExDaytona.FSTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.FS
  alias ExDaytona.Model
  alias ExDaytona.Sandbox

  setup do
    bypass = MockServer.setup()

    {:ok, client} =
      Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass), retry: false)

    sandbox = %Sandbox{
      client: client,
      info: %Model.Sandbox{
        id: "sb-1",
        state: "started",
        toolboxProxyUrl: MockServer.url(bypass) <> "/toolbox"
      }
    }

    {:ok, bypass: bypass, sandbox: sandbox}
  end

  describe "directories & metadata" do
    test "mkdir/3 sends path and mode", %{bypass: bypass, sandbox: sandbox} do
      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/files/folder", fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["path"] == "/workspace/data"
        assert query["mode"] == "700"

        Plug.Conn.resp(conn, 201, "")
      end)

      assert :ok = FS.mkdir(sandbox, "/workspace/data", mode: "700")
    end

    test "stat/2 decodes FileInfo", %{bypass: bypass, sandbox: sandbox} do
      Bypass.expect_once(bypass, "GET", "/toolbox/sb-1/files/info", fn conn ->
        assert URI.decode_query(conn.query_string)["path"] == "/workspace/a.txt"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!(%{name: "a.txt", isDir: false, size: 5, mode: "-rw-r--r--"})
        )
      end)

      assert {:ok, %Model.FileInfo{name: "a.txt", size: 5}} =
               FS.stat(sandbox, "/workspace/a.txt")
    end

    test "delete/3 forwards recursive", %{bypass: bypass, sandbox: sandbox} do
      Bypass.expect_once(bypass, "DELETE", "/toolbox/sb-1/files", fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["path"] == "/workspace/old"
        assert query["recursive"] == "true"

        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = FS.delete(sandbox, "/workspace/old", recursive: true)
    end

    test "move/3 sends source and destination", %{bypass: bypass, sandbox: sandbox} do
      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/files/move", fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["source"] == "/a.txt"
        assert query["destination"] == "/b.txt"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{}))
      end)

      assert :ok = FS.move(sandbox, "/a.txt", "/b.txt")
    end

    test "chmod/3 sends mode/owner/group", %{bypass: bypass, sandbox: sandbox} do
      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/files/permissions", fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["path"] == "/a.txt"
        assert query["mode"] == "644"
        assert query["owner"] == "daytona"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{}))
      end)

      assert :ok = FS.chmod(sandbox, "/a.txt", mode: "644", owner: "daytona")
    end
  end

  describe "search & replace" do
    test "search/3 returns matching paths", %{bypass: bypass, sandbox: sandbox} do
      Bypass.expect_once(bypass, "GET", "/toolbox/sb-1/files/search", fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["path"] == "/workspace"
        assert query["pattern"] == "*.ex"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{files: ["/workspace/a.ex", "/workspace/b.ex"]}))
      end)

      assert {:ok, ["/workspace/a.ex", "/workspace/b.ex"]} =
               FS.search(sandbox, "/workspace", "*.ex")
    end

    test "grep/3 decodes matches", %{bypass: bypass, sandbox: sandbox} do
      MockServer.expect_get(bypass, "/toolbox/sb-1/files/find", 200, [
        %{file: "/workspace/a.ex", line: 3, content: "# TODO fix"}
      ])

      assert {:ok, [%Model.Match{file: "/workspace/a.ex", line: 3, content: "# TODO fix"}]} =
               FS.grep(sandbox, "/workspace", "TODO")
    end

    test "replace/4 posts the request and decodes per-file results", %{
      bypass: bypass,
      sandbox: sandbox
    } do
      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/files/replace", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{"files" => ["/a.txt"], "pattern" => "old", "newValue" => "new"} =
                 JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!([%{file: "/a.txt", success: true}]))
      end)

      assert {:ok, [%Model.ReplaceResult{file: "/a.txt", success: true}]} =
               FS.replace(sandbox, ["/a.txt"], "old", "new")
    end
  end

  describe "local <-> sandbox transfer" do
    setup do
      dir = Path.join(System.tmp_dir!(), "ex_daytona_fs_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "upload/3 reads a local file and writes it remotely", %{
      bypass: bypass,
      sandbox: sandbox,
      dir: dir
    } do
      local = Path.join(dir, "up.txt")
      File.write!(local, "local content")

      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/files/upload-v2", fn conn ->
        assert URI.decode_query(conn.query_string)["path"] == "/workspace/up.txt"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "local content"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{name: "up.txt"}))
      end)

      assert :ok = FS.upload(sandbox, local, "/workspace/up.txt")
    end

    test "upload/3 fails cleanly on a missing local file", %{sandbox: sandbox, dir: dir} do
      assert {:error, %Error{message: message}} =
               FS.upload(sandbox, Path.join(dir, "nope.txt"), "/workspace/x")

      assert message =~ "cannot read"
    end

    test "download/3 writes the remote file locally", %{
      bypass: bypass,
      sandbox: sandbox,
      dir: dir
    } do
      Bypass.expect_once(bypass, "GET", "/toolbox/sb-1/files/download", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.resp(200, "remote bytes")
      end)

      local = Path.join(dir, "down.bin")
      assert :ok = FS.download(sandbox, "/workspace/file.bin", local)
      assert File.read!(local) == "remote bytes"
    end

    test "write_files/2 writes each entry and stops on failure", %{
      bypass: bypass,
      sandbox: sandbox
    } do
      Bypass.expect(bypass, "POST", "/toolbox/sb-1/files/upload-v2", fn conn ->
        case URI.decode_query(conn.query_string)["path"] do
          "/ok.txt" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(200, JSON.encode!(%{}))

          "/fail.txt" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(400, JSON.encode!(%{message: "nope", statusCode: 400}))
        end
      end)

      assert :ok = FS.write_files(sandbox, [{"/ok.txt", "a"}])

      assert {:error, %Error{status: 400}} =
               FS.write_files(sandbox, [{"/ok.txt", "a"}, {"/fail.txt", "b"}])
    end
  end
end
