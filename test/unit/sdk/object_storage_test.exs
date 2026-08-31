defmodule ExDaytona.ObjectStorageTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.ObjectStorage

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "ex_daytona_ctx_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp push_access_response do
    %{
      accessKey: "AKIDEXAMPLE",
      secret: "sekret",
      sessionToken: "sess-tok",
      bucket: "daytona-builds",
      storageUrl: nil,
      region: "us-east-1",
      organizationId: "org-1"
    }
  end

  describe "archive_base_path/1" do
    test "normalizes and strips the leading separator" do
      assert ObjectStorage.archive_base_path("/tmp/app/mix.exs") == "tmp/app/mix.exs"
      assert ObjectStorage.archive_base_path("relative/file.txt") == "relative/file.txt"
      assert ObjectStorage.archive_base_path("./relative/file.txt") == "relative/file.txt"
    end
  end

  describe "hash_path/2" do
    test "is deterministic and content-sensitive for files" do
      dir = tmp_dir!()
      file = Path.join(dir, "a.txt")
      File.write!(file, "hello")

      hash = ObjectStorage.hash_path(file, "ctx/a.txt")

      assert hash == ObjectStorage.hash_path(file, "ctx/a.txt")
      assert hash =~ ~r/^[0-9a-f]{32}$/

      # Different archive path -> different hash (it salts the hash)
      refute hash == ObjectStorage.hash_path(file, "other/a.txt")

      File.write!(file, "changed")
      refute hash == ObjectStorage.hash_path(file, "ctx/a.txt")
    end

    test "hashes directories recursively" do
      dir = tmp_dir!()
      File.mkdir_p!(Path.join(dir, "sub"))
      File.write!(Path.join(dir, "root.txt"), "r")
      File.write!(Path.join(dir, "sub/nested.txt"), "n")

      hash = ObjectStorage.hash_path(dir, "ctx")
      assert hash == ObjectStorage.hash_path(dir, "ctx")

      File.write!(Path.join(dir, "sub/nested.txt"), "changed")
      refute hash == ObjectStorage.hash_path(dir, "ctx")
    end
  end

  describe "upload_context_with_access/3 (against a mock S3)" do
    test "HEAD miss -> PUT tar with SigV4 auth; HEAD hit -> skip upload", %{} do
      bypass = MockServer.setup()

      access =
        %{
          access_key: "AKIDEXAMPLE",
          secret: "sekret",
          session_token: "sess-tok",
          bucket: "daytona-builds",
          storage_url: "http://localhost:#{bypass.port}",
          region: "us-east-1",
          organization_id: "org-1"
        }

      dir = tmp_dir!()
      file = Path.join(dir, "hello.txt")
      File.write!(file, "hello context")

      archive_path = ObjectStorage.archive_base_path(file)
      hash = ObjectStorage.hash_path(file, archive_path)
      key = "/daytona-builds/org-1/#{hash}/context.tar"

      MockServer.expect_once(bypass, "HEAD", key, fn conn ->
        # SigV4 headers present
        assert [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth =~ "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/"
        assert auth =~ "/us-east-1/s3/aws4_request"
        assert ["sess-tok"] = Plug.Conn.get_req_header(conn, "x-amz-security-token")

        Plug.Conn.resp(conn, 404, "")
      end)

      MockServer.expect_once(bypass, "PUT", key, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

        # The body is a tar containing the file under its archive path
        tar_tmp = Path.join(System.tmp_dir!(), "assert_#{System.unique_integer([:positive])}.tar")
        File.write!(tar_tmp, body)
        {:ok, entries} = :erl_tar.table(String.to_charlist(tar_tmp))
        File.rm!(tar_tmp)

        assert Enum.any?(entries, fn entry ->
                 to_string(entry) == archive_path
               end)

        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, ^hash} =
               ObjectStorage.upload_context_with_access(access, file, archive_path: archive_path)

      # Second call: HEAD hits, no PUT expected
      MockServer.expect_once(bypass, "HEAD", key, fn conn -> Plug.Conn.resp(conn, 200, "") end)

      assert {:ok, ^hash} =
               ObjectStorage.upload_context_with_access(access, file, archive_path: archive_path)
    end

    test "a missing source path fails cleanly" do
      access = %{
        access_key: "a",
        secret: "s",
        session_token: nil,
        bucket: "b",
        storage_url: "http://localhost:1",
        region: "us-east-1",
        organization_id: "org-1"
      }

      assert {:error, %Error{message: message}} =
               ObjectStorage.upload_context_with_access(access, "/nope/missing.txt")

      assert message =~ "does not exist"
    end
  end

  describe "push_access/1" do
    test "normalizes the DTO to snake_case", %{} do
      bypass = MockServer.setup()

      {:ok, client} =
        Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass), retry: false)

      MockServer.expect_get(
        bypass,
        "/object-storage/push-access",
        200,
        push_access_response()
      )

      assert {:ok,
              %{
                access_key: "AKIDEXAMPLE",
                secret: "sekret",
                session_token: "sess-tok",
                bucket: "daytona-builds",
                organization_id: "org-1",
                region: "us-east-1"
              }} = ObjectStorage.push_access(client)
    end
  end
end
