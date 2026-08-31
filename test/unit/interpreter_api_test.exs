defmodule ExDaytona.Api.InterpreterTest do
  use TestCase, async: true

  alias ExDaytona.Api.Interpreter
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "list_interpreter_contexts/2" do
    test "decodes the ListContextsResponse", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/process/interpreter/context", 200, %{
        contexts: [%{id: "ctx-1", language: "python", active: true}]
      })

      assert {:ok, %Model.ListContextsResponse{contexts: [ctx]}} =
               Interpreter.list_interpreter_contexts(conn)

      assert %Model.InterpreterContext{id: "ctx-1", language: "python", active: true} = ctx
    end
  end

  describe "create_interpreter_context/3" do
    test "posts the request and decodes the InterpreterContext", %{bypass: bypass, conn: conn} do
      Bypass.expect_once(bypass, "POST", "/process/interpreter/context", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"language" => "python"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "ctx-new", language: "python"}))
      end)

      assert {:ok, %Model.InterpreterContext{id: "ctx-new"}} =
               Interpreter.create_interpreter_context(conn, %Model.CreateContextRequest{
                 language: "python"
               })
    end
  end
end
