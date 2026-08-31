defmodule ExDaytona.CodeInterpreterTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.CodeInterpreter
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Sandbox

  defp build_sandbox(base_url) do
    {:ok, client} = Client.new(api_key: "dtn_test", base_url: base_url, retry: false)

    %Sandbox{
      client: client,
      info: %Model.Sandbox{
        id: "sb-1",
        state: "started",
        toolboxProxyUrl: base_url <> "/toolbox"
      }
    }
  end

  describe "run/3 (over the interpreter websocket protocol)" do
    test "aggregates streamed stdout/stderr and invokes callbacks" do
      port = WsEchoServer.start_interpreter()
      sandbox = build_sandbox("http://localhost:#{port}")

      {:ok, streamed} = Agent.start_link(fn -> [] end)

      assert {:ok, %{stdout: stdout, stderr: "warn\n", error: nil}} =
               CodeInterpreter.run(sandbox, "print(1)", on_stdout: fn text -> Agent.update(streamed, &[text | &1]) end)

      assert stdout == "ran:print(1) ctx:default"
      assert Agent.get(streamed, &Enum.reverse/1) == ["ran:print(1)", " ctx:default"]
    end

    test "passes the context id and surfaces execution errors" do
      port = WsEchoServer.start_interpreter()
      sandbox = build_sandbox("http://localhost:#{port}")
      context = %Model.InterpreterContext{id: "ctx-9"}

      {:ok, errors} = Agent.start_link(fn -> [] end)

      assert {:ok, %{stdout: stdout, error: error}} =
               CodeInterpreter.run(sandbox, "raise X",
                 context: context,
                 on_error: fn e -> Agent.update(errors, &[e | &1]) end
               )

      assert stdout =~ "ctx:ctx-9"
      assert %{name: "RuntimeError", value: "boom", traceback: "trace..."} = error
      assert [%{name: "RuntimeError"}] = Agent.get(errors, & &1)
    end

    test "times out client-side with a clear error" do
      # The echo server never sends interpreter chunks nor closes after a
      # text frame reply, so run/3 waits until receive_timeout.
      port = WsEchoServer.start()
      sandbox = build_sandbox("http://localhost:#{port}")

      assert {:error, %Error{message: message}} =
               CodeInterpreter.run(sandbox, "print(1)", receive_timeout: 200)

      assert message =~ "timed out"
    end
  end

  describe "contexts" do
    setup do
      bypass = MockServer.setup()
      sandbox = build_sandbox(MockServer.url(bypass))
      {:ok, bypass: bypass, sandbox: sandbox}
    end

    test "create_context/2 posts cwd and decodes", %{bypass: bypass, sandbox: sandbox} do
      MockServer.expect_once(bypass, "POST", "/toolbox/sb-1/process/interpreter/context", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"cwd" => "/workspace", "language" => "python"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "ctx-1", cwd: "/workspace", active: true}))
      end)

      assert {:ok, %Model.InterpreterContext{id: "ctx-1", cwd: "/workspace"}} =
               CodeInterpreter.create_context(sandbox, cwd: "/workspace")
    end

    test "list_contexts/1 and delete_context/2", %{bypass: bypass, sandbox: sandbox} do
      MockServer.expect_get(bypass, "/toolbox/sb-1/process/interpreter/context", 200, %{
        contexts: [%{id: "ctx-1", language: "python"}]
      })

      assert {:ok, [%Model.InterpreterContext{id: "ctx-1"}]} =
               CodeInterpreter.list_contexts(sandbox)

      MockServer.expect_once(
        bypass,
        "DELETE",
        "/toolbox/sb-1/process/interpreter/context/ctx-1",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, JSON.encode!(%{}))
        end
      )

      assert :ok = CodeInterpreter.delete_context(sandbox, "ctx-1")
    end
  end
end
