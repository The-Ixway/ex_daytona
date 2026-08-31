defmodule ExDaytona.GitTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Git
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

  describe "clone/4" do
    test "posts the clone request and returns :ok", %{bypass: bypass, sandbox: sandbox} do
      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/git/clone", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{
                 "url" => "https://example.com/repo.git",
                 "path" => "/tmp/repo",
                 "branch" => "main",
                 "depth" => 1
               } = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{}))
      end)

      assert :ok =
               Git.clone(sandbox, "https://example.com/repo.git", "/tmp/repo",
                 branch: "main",
                 depth: 1
               )
    end

    test "a spec-declared 404 normalizes to an error", %{bypass: bypass, sandbox: sandbox} do
      # Real Daytona error bodies carry statusCode; a spec-declared error
      # model is the only place Error.normalize can read the status from.
      MockServer.expect_post(bypass, "/toolbox/sb-1/git/clone", 404, %{
        message: "repository not found",
        statusCode: 404
      })

      assert {:error, %Error{status: 404, message: "repository not found"}} =
               Git.clone(sandbox, "https://example.com/nope.git", "/tmp/repo")
    end
  end

  describe "status/2 and branches/2" do
    test "decode into ergonomic shapes", %{bypass: bypass, sandbox: sandbox} do
      Bypass.expect_once(bypass, "GET", "/toolbox/sb-1/git/status", fn conn ->
        assert URI.decode_query(conn.query_string)["path"] == "/tmp/repo"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{currentBranch: "main", ahead: 2, behind: 0}))
      end)

      assert {:ok, %Model.GitStatus{currentBranch: "main", ahead: 2}} =
               Git.status(sandbox, "/tmp/repo")

      MockServer.expect_get(bypass, "/toolbox/sb-1/git/branches", 200, %{
        branches: ["main", "dev"],
        current: "main"
      })

      assert {:ok, %{branches: ["main", "dev"], current: "main"}} =
               Git.branches(sandbox, "/tmp/repo")
    end
  end

  describe "add/3 + commit/4" do
    test "stages files and commits with author info", %{bypass: bypass, sandbox: sandbox} do
      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/git/add", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"path" => "/tmp/repo", "files" => ["a.txt"]} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{}))
      end)

      assert :ok = Git.add(sandbox, "/tmp/repo", ["a.txt"])

      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/git/commit", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{
                 "path" => "/tmp/repo",
                 "message" => "feat: add a",
                 "author" => "Dev",
                 "email" => "dev@example.com"
               } = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{hash: "abc123"}))
      end)

      assert {:ok, %{hash: "abc123"}} =
               Git.commit(sandbox, "/tmp/repo", "feat: add a",
                 author: "Dev",
                 email: "dev@example.com"
               )
    end

    test "commit without author/email fails before any request", %{sandbox: sandbox} do
      assert {:error, %Error{message: message}} = Git.commit(sandbox, "/tmp/repo", "msg", [])
      assert message =~ ":author"
    end
  end

  describe "push/3 and pull/3" do
    test "forward credentials in the request body", %{bypass: bypass, sandbox: sandbox} do
      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/git/push", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{"path" => "/tmp/repo", "username" => "bot", "password" => "token"} =
                 JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{}))
      end)

      assert :ok = Git.push(sandbox, "/tmp/repo", username: "bot", password: "token")

      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/git/pull", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{}))
      end)

      assert :ok = Git.pull(sandbox, "/tmp/repo")
    end
  end

  describe "branch management + history" do
    test "create_branch, checkout, and history", %{bypass: bypass, sandbox: sandbox} do
      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/git/branches", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"name" => "feature/x"} = JSON.decode!(body)

        Plug.Conn.resp(conn, 201, "")
      end)

      assert :ok = Git.create_branch(sandbox, "/tmp/repo", "feature/x")

      Bypass.expect_once(bypass, "POST", "/toolbox/sb-1/git/checkout", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"branch" => "feature/x"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{}))
      end)

      assert :ok = Git.checkout(sandbox, "/tmp/repo", "feature/x")

      MockServer.expect_get(bypass, "/toolbox/sb-1/git/history", 200, [
        %{hash: "abc", message: "feat: x", author: "Dev"}
      ])

      assert {:ok, [%Model.GitCommitInfo{hash: "abc", message: "feat: x"}]} =
               Git.history(sandbox, "/tmp/repo")
    end
  end
end
