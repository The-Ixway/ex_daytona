defmodule ExDaytona.Api.LspTest do
  use TestCase, async: true

  alias ExDaytona.Api.Lsp
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "completions/3" do
    test "posts the params and decodes the CompletionList", %{bypass: bypass, conn: conn} do
      MockServer.expect_once(bypass, "POST", "/lsp/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"languageId" => "elixir"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!(%{isIncomplete: false, items: [%{label: "Enum.map/2"}]})
        )
      end)

      params = %Model.LspCompletionParams{
        languageId: "elixir",
        pathToProject: "/workspace/repo",
        uri: "file:///workspace/repo/lib/foo.ex"
      }

      assert {:ok, %Model.CompletionList{isIncomplete: false, items: [_]}} =
               Lsp.completions(conn, params)
    end
  end

  describe "start/3" do
    test "a spec-declared 400 decodes into the error model (as :ok)", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_post(bypass, "/lsp/start", 400, %{message: "unsupported language"})

      request = %Model.LspServerRequest{languageId: "cobol", pathToProject: "/workspace"}

      assert {:ok, %Model.ErrorResponse{message: "unsupported language"}} =
               Lsp.start(conn, request)
    end
  end
end
