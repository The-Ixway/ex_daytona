defmodule ExDaytona.Api.ProcessTest do
  use TestCase, async: true

  alias ExDaytona.Api.Process
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "execute_command/3" do
    test "posts the command and decodes the result", %{bypass: bypass, conn: conn} do
      MockServer.expect_once(bypass, "POST", "/process/execute", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"command" => "echo hello"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{exitCode: 0, result: "hello\n"}))
      end)

      assert {:ok, %Model.ExecuteResponse{exitCode: 0, result: "hello\n"}} =
               Process.execute_command(conn, %Model.ExecuteRequest{command: "echo hello"})
    end

    test "a spec-declared 400 decodes into the error model (as :ok)", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_post(bypass, "/process/execute", 400, %{
        message: "command is required"
      })

      # Spec-mapped error statuses return {:ok, error_struct} — an
      # openapi-generator convention. Callers must match on the struct.
      assert {:ok, %Model.ErrorResponse{message: "command is required"}} =
               Process.execute_command(conn, %Model.ExecuteRequest{command: ""})
    end
  end

  describe "create_session/3" do
    test "creates a session (201 is mapped as raw env)", %{bypass: bypass, conn: conn} do
      MockServer.expect_post(bypass, "/process/session", 201, %{})

      assert {:ok, %Tesla.Env{status: 201}} =
               Process.create_session(conn, %Model.CreateSessionRequest{sessionId: "sess-1"})
    end
  end
end
