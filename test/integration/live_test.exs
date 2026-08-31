defmodule LiveSmokeTest do
  @moduledoc """
  Live smoke tests against a real API deployment.

  The Bypass/Mox unit suite mocks the API *from the spec* — so it can never
  catch places where the spec and the real server disagree: undeclared error
  statuses, auth-header handling, decode mismatches. These tests close that
  gap by exercising the SDK against a real server.

  Tagged `:live` and excluded from `mix test`; run with:

      SDK_LIVE_BASE_URL=https://api.example.com SDK_LIVE_TOKEN=... mix test.live

  Optional environment variables:

    * `SDK_LIVE_HEALTH_PATH` — a path that answers unauthenticated GETs
      (default `/`)
    * `SDK_LIVE_AUTH_PATH` — a path that requires authentication (default `/`)

  Most tests here are SDK-agnostic and work as-is. The tests tagged
  `@tag :skip` under "typed operations" are the per-SDK customization points:
  replace the placeholder with one or two real operation calls, then delete
  the skip tag.
  """

  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 30_000

  alias ExDaytona.Api.Sandbox, as: SandboxApi
  alias ExDaytona.Model

  @connection SdkSurface.connection_module()

  setup_all do
    base_url = System.get_env("SDK_LIVE_BASE_URL")

    if base_url in [nil, ""] do
      raise """
      SDK_LIVE_BASE_URL is not set.

      Live smoke tests need a real deployment to talk to:

          SDK_LIVE_BASE_URL=https://api.example.com SDK_LIVE_TOKEN=... mix test.live
      """
    end

    {:ok, base_url: base_url, token: System.get_env("SDK_LIVE_TOKEN")}
  end

  # Builds a client for the live server. `bearer_token` is ignored by
  # Connection when the spec defines no bearer scheme, so this stays generic.
  defp live_client(ctx, opts \\ []) do
    auth = if ctx[:token], do: [bearer_token: ctx.token], else: []

    @connection.new([base_url: ctx.base_url, retry: false] ++ auth ++ opts)
  end

  describe "transport" do
    test "the live base URL is reachable and answers HTTP", ctx do
      path = System.get_env("SDK_LIVE_HEALTH_PATH", "/")

      assert {:ok, %Tesla.Env{status: status}} =
               @connection.request(live_client(ctx), method: :get, url: path)

      assert status in 200..599
    end

    test "requests emit telemetry", ctx do
      handler_id = "live-smoke-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:tesla, :request, :stop],
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      @connection.request(live_client(ctx), method: :get, url: "/")

      assert_receive {:telemetry, %{duration: _}, _metadata}, 15_000
    end

    test "an unreachable host returns an adapter error tuple" do
      client = @connection.new(base_url: "http://localhost:9", retry: false)

      # The reason term is adapter-specific (e.g. %Finch.TransportError{} for
      # the default adapter) — assert only the tuple shape here.
      assert {:error, _reason} = @connection.request(client, method: :get, url: "/")
    end
  end

  describe "authentication" do
    test "a bogus bearer token is rejected as an auth failure", ctx do
      path = System.get_env("SDK_LIVE_AUTH_PATH", "/")

      client =
        @connection.new(
          base_url: ctx.base_url,
          bearer_token: "invalid-#{System.unique_integer([:positive])}",
          retry: false
        )

      assert {:ok, %Tesla.Env{status: status}} =
               @connection.request(client, method: :get, url: path)

      assert status in [401, 403]
    end
  end

  describe "typed operations" do
    # Read-only: lists sandboxes without creating anything. This is the test
    # that catches spec-vs-server decode mismatches.
    test "a basic read operation succeeds and decodes into a typed struct", ctx do
      assert {:ok, %Model.ListSandboxesResponse{items: items}} =
               SandboxApi.list_sandboxes(live_client(ctx))

      assert is_list(items)
      assert Enum.all?(items, &match?(%Model.SandboxListItem{}, &1))
    end

    # Proves query params survive the request builder + middleware stack
    # against a real server.
    test "query parameters are transmitted and honored", ctx do
      assert {:ok, %Model.ListSandboxesResponse{items: items}} =
               SandboxApi.list_sandboxes(live_client(ctx), limit: 1)

      assert length(items) <= 1
    end

    # The main platform spec declares almost no error statuses, so real
    # error responses take the undeclared-status path: `{:error, env}` with
    # the JSON body decoded to a map. Read-only: fetches a sandbox that
    # cannot exist.
    test "an undeclared error status surfaces as an error tuple with a decoded body", ctx do
      bogus_id = "live-smoke-does-not-exist-#{System.unique_integer([:positive])}"

      assert {:error, %Tesla.Env{status: status, body: body}} =
               SandboxApi.get_sandbox(live_client(ctx), bogus_id)

      assert status in [400, 401, 403, 404]
      assert is_map(body) or is_binary(body)
    end
  end

  describe "facade lifecycle (creates real resources)" do
    # Unlike the rest of this suite, this test CREATES (and deletes) a real
    # sandbox — it is skipped unless explicitly opted into:
    #
    #     SDK_LIVE_LIFECYCLE=1 SDK_LIVE_TOKEN=... mix test.live
    #
    @tag timeout: 300_000
    test "create -> exec -> files -> stop/start -> delete via the facade", ctx do
      if System.get_env("SDK_LIVE_LIFECYCLE") != "1" do
        IO.puts("skipping facade lifecycle test (set SDK_LIVE_LIFECYCLE=1 to run)")
      else
        {:ok, client} =
          ExDaytona.Client.new(api_key: ctx.token, base_url: ctx.base_url, retry: false)

        {:ok, sandbox} =
          ExDaytona.Sandbox.create(client,
            labels: %{"purpose" => "ex_daytona-live-lifecycle"},
            ttl_minutes: 15
          )

        try do
          assert ExDaytona.Sandbox.state(sandbox) == "started"

          assert {:ok, %{exit_code: 0, output: output}} =
                   ExDaytona.Sandbox.exec(sandbox, "echo live-lifecycle")

          assert output =~ "live-lifecycle"

          assert :ok = ExDaytona.Sandbox.write_file(sandbox, "/tmp/live.txt", "roundtrip")
          assert {:ok, "roundtrip"} = ExDaytona.Sandbox.read_file(sandbox, "/tmp/live.txt")

          # Sessions: shared state, async command, real-time log streaming
          {:ok, session} = ExDaytona.Session.create(sandbox)
          {:ok, %{exit_code: 0}} = ExDaytona.Session.run(session, "export LIVE_MARKER=ok")
          {:ok, %{output: marker_out}} = ExDaytona.Session.run(session, "echo $LIVE_MARKER")
          assert marker_out =~ "ok"

          {:ok, cmd_id} = ExDaytona.Session.run_async(session, "echo s1; sleep 1; echo s2")

          {:ok, chunks} = Agent.start_link(fn -> [] end)

          assert :ok =
                   ExDaytona.Session.stream_logs(
                     session,
                     cmd_id,
                     fn chunk -> Agent.update(chunks, &[chunk | &1]) end,
                     timeout: 60_000
                   )

          streamed = chunks |> Agent.get(& &1) |> Enum.reverse() |> Enum.join()
          assert streamed =~ "s1"
          assert streamed =~ "s2"

          assert {:ok, %{exit_code: 0}} =
                   ExDaytona.Session.await(session, cmd_id, poll_interval: 500)

          assert {:ok, logs} = ExDaytona.Session.logs(session, cmd_id)
          assert logs =~ "s1"
          assert :ok = ExDaytona.Session.delete(session)

          # PTY: interactive terminal over a websocket
          {:ok, pty} = ExDaytona.Pty.create(sandbox, cols: 120, rows: 30)
          {:ok, ws} = ExDaytona.Pty.connect(pty)
          :ok = ExDaytona.Pty.send_input(ws, "echo PTY-$((6*7))\n")

          pty_output =
            Enum.reduce_while(1..20, "", fn _, acc ->
              receive do
                {:ex_daytona_ws, ^ws, {:binary, data}} ->
                  acc = acc <> data
                  if acc =~ "PTY-42", do: {:halt, acc}, else: {:cont, acc}

                {:ex_daytona_ws, ^ws, {:text, data}} ->
                  {:cont, acc <> data}
              after
                1_000 -> {:cont, acc}
              end
            end)

          assert pty_output =~ "PTY-42"
          :ok = ExDaytona.Pty.disconnect(ws)
          :ok = ExDaytona.Pty.delete(pty)

          # SSH access + preview URLs
          {:ok, %{token: ssh_token, ssh_command: ssh_command}} =
            ExDaytona.Sandbox.ssh_access(sandbox, expires_in_minutes: 5)

          assert is_binary(ssh_token)
          assert ssh_command =~ "ssh "
          assert :ok = ExDaytona.Sandbox.revoke_ssh_access(sandbox)

          {:ok, %{url: preview_url}} = ExDaytona.Sandbox.preview_url(sandbox, 3000)
          assert preview_url =~ "3000"

          {:ok, %{url: signed_url, token: signed_token}} =
            ExDaytona.Sandbox.signed_preview_url(sandbox, 3000, expires_in_seconds: 300)

          assert signed_url =~ "http"
          assert :ok = ExDaytona.Sandbox.expire_signed_preview_url(sandbox, 3000, signed_token)

          # Git: clone a small public repo and inspect it
          repo = "/tmp/live-repo"

          assert :ok =
                   ExDaytona.Git.clone(
                     sandbox,
                     "https://github.com/octocat/Hello-World.git",
                     repo
                   )

          assert {:ok, git_status} = ExDaytona.Git.status(sandbox, repo)
          assert is_binary(git_status.currentBranch)
          assert {:ok, [_ | _]} = ExDaytona.Git.history(sandbox, repo)

          assert {:ok, stopped} = ExDaytona.Sandbox.stop(sandbox, poll_interval: 2_000)
          assert ExDaytona.Sandbox.state(stopped) == "stopped"

          assert {:ok, restarted} = ExDaytona.Sandbox.start(stopped, poll_interval: 2_000)
          assert ExDaytona.Sandbox.state(restarted) == "started"
        after
          :ok = ExDaytona.Sandbox.delete(sandbox)
        end
      end
    end
  end
end
