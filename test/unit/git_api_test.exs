defmodule ExDaytona.Api.GitTest do
  use TestCase, async: true

  alias ExDaytona.Api.Git
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_status/3" do
    test "sends the repo path as a query parameter and decodes GitStatus", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_once(bypass, "GET", "/git/status", fn conn ->
        assert URI.decode_query(conn.query_string)["path"] == "/workspace/repo"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!(%{currentBranch: "main", ahead: 1, behind: 0, detached: false})
        )
      end)

      assert {:ok, %Model.GitStatus{currentBranch: "main", ahead: 1, behind: 0}} =
               Git.get_status(conn, "/workspace/repo")
    end
  end

  describe "list_branches/3" do
    test "decodes the branch list", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/git/branches", 200, %{
        branches: ["main", "feature/x"],
        current: "main"
      })

      assert {:ok, %Model.ListBranchResponse{branches: ["main", "feature/x"], current: "main"}} =
               Git.list_branches(conn, "/workspace/repo")
    end
  end

  describe "commit_changes/3" do
    test "posts the commit request and decodes the hash", %{bypass: bypass, conn: conn} do
      MockServer.expect_once(bypass, "POST", "/git/commit", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"message" => "feat: add thing", "path" => "/workspace/repo"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{hash: "abc123"}))
      end)

      request = %Model.GitCommitRequest{
        path: "/workspace/repo",
        message: "feat: add thing",
        author: "Dev",
        email: "dev@example.com"
      }

      assert {:ok, %Model.GitCommitResponse{hash: "abc123"}} = Git.commit_changes(conn, request)
    end
  end

  describe "clone_repository/3" do
    test "a spec-declared 404 decodes into the error model (as :ok)", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_post(bypass, "/git/clone", 404, %{message: "repository not found"})

      request = %Model.GitCloneRequest{url: "https://example.com/nope.git", path: "/workspace"}

      assert {:ok, %Model.ErrorResponse{message: "repository not found"}} =
               Git.clone_repository(conn, request)
    end
  end
end
