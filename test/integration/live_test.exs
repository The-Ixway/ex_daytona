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

        # Create-time secret binding: the secret must exist before the
        # sandbox binds it.
        secret_name = "ex-daytona-live-#{System.unique_integer([:positive])}"
        secret_value = "live-secret-value-#{System.unique_integer([:positive])}"
        {:ok, secret} = ExDaytona.Secrets.create(client, secret_name, secret_value)

        {:ok, sandbox} =
          ExDaytona.Sandbox.create(client,
            labels: %{"purpose" => "ex_daytona-live-lifecycle"},
            ttl_minutes: 15,
            secrets: [%{"LIVE_BOUND_SECRET" => secret_name}]
          )

        try do
          assert ExDaytona.Sandbox.state(sandbox) == "started"

          # Live contract: the sandbox env var carries a PLACEHOLDER handle
          # (dtn_secret_...), never the plaintext — values are materialized
          # by the platform per the secret's hosts allowlist.
          assert {:ok, %{exit_code: 0, output: secret_out}} =
                   ExDaytona.Sandbox.exec(sandbox, "printenv LIVE_BOUND_SECRET")

          placeholder = String.trim(secret_out)
          assert placeholder =~ "dtn_secret_"
          refute placeholder == secret_value

          # The resolve endpoint (plaintext values) authenticates platform
          # infrastructure, not user API keys — expect the documented 403.
          case ExDaytona.Secrets.resolve(sandbox) do
            {:error, %ExDaytona.Error{status: 403}} ->
              :infra_gated_as_documented

            {:ok, resolved} ->
              binding = Enum.find(resolved, &(&1.env == "LIVE_BOUND_SECRET"))
              assert binding
              assert binding.value == secret_value
              refute inspect(resolved) =~ secret_value

            other ->
              flunk("unexpected resolve result: #{inspect(other)}")
          end

          assert {:ok, %{exit_code: 0, output: output}} =
                   ExDaytona.Sandbox.exec(sandbox, "echo live-lifecycle")

          assert output =~ "live-lifecycle"

          assert :ok = ExDaytona.Sandbox.write_file(sandbox, "/tmp/live.txt", "roundtrip")
          assert {:ok, "roundtrip"} = ExDaytona.Sandbox.read_file(sandbox, "/tmp/live.txt")

          # Constant-memory streaming transfer: 4MB round-trip with checksums
          four_mb = :crypto.strong_rand_bytes(4 * 1024 * 1024)
          upload_sha = :sha256 |> :crypto.hash(four_mb) |> Base.encode16(case: :lower)
          chunks = for <<chunk::binary-size(64 * 1024) <- four_mb>>, do: chunk

          assert {:ok, %{bytes: up_bytes, sha256: ^upload_sha}} =
                   ExDaytona.FS.upload_stream(sandbox, "/tmp/stream.bin", chunks, expected_sha256: upload_sha)

          assert up_bytes == byte_size(four_mb)

          stream_dl = Path.join(System.tmp_dir!(), "ex_daytona_live_dl.bin")
          File.rm(stream_dl)

          assert {:ok, %{sha256: ^upload_sha}} =
                   ExDaytona.FS.download_file(sandbox, "/tmp/stream.bin", stream_dl, expected_sha256: upload_sha)

          assert File.stat!(stream_dl).size == byte_size(four_mb)
          File.rm!(stream_dl)

          # Stream cancellation mid-download closes cleanly
          {:ok, cancel_seen} = Agent.start_link(fn -> 0 end)

          cancel_consumer = fn _chunk ->
            if Agent.get_and_update(cancel_seen, &{&1 + 1, &1 + 1}) >= 1, do: :halt, else: :ok
          end

          assert {:error, %ExDaytona.Error{message: cancel_msg}} =
                   ExDaytona.FS.download_stream(sandbox, "/tmp/stream.bin", cancel_consumer)

          assert cancel_msg =~ "canceled"

          # Response and rate-limit metadata on success and error paths
          assert {:ok, %ExDaytona.Response{} = full} =
                   ExDaytona.Api.Sandbox.get_sandbox(
                     ExDaytona.Client.conn(client),
                     ExDaytona.Sandbox.id(sandbox),
                     response: :full
                   )

          assert full.status == 200
          assert ExDaytona.Response.get_header(full, "content-type") =~ "json"

          # request id / rate-limit headers are provider-optional (the
          # platform's success responses omit x-request-id; the toolbox
          # sends it) — assert the parsers ran without demanding presence
          if full.request_id, do: assert(is_binary(full.request_id))
          if full.rate_limit, do: assert(is_map(full.rate_limit))

          assert {:error, %ExDaytona.Error{status: 404} = not_found} =
                   ExDaytona.Sandbox.get(client, "missing-#{System.unique_integer([:positive])}")

          # error metadata pipeline attached the response headers
          assert is_list(not_found.headers) and not_found.headers != []
          if not_found.request_id, do: assert(is_binary(not_found.request_id))

          # Runtime network policy update — organizations on tiers with
          # enforced network restrictions reject sandbox-level overrides
          # (400 with a docs link); both outcomes exercise the facade.
          sandbox =
            case ExDaytona.Sandbox.update_network_settings(sandbox,
                   domain_allow_list: "example.com,*.daytona.io"
                 ) do
              {:ok, updated} ->
                assert updated.info.domainAllowList =~ "example.com"
                updated

              {:error, %ExDaytona.Error{status: 400, message: message}} ->
                assert message =~ "restricted"
                sandbox
            end

          # Quota primitives: org truth via the sandbox's own org id
          org_id = sandbox.info.organizationId

          assert {:ok, quota} = ExDaytona.Quota.overview(client, org_id)
          assert is_list(quota.regions)

          # Quota.limits reads the organization record — JWT-gated (401
          # with API keys, documented); overview above carries per-sandbox
          # maxima for API-key callers.
          case ExDaytona.Quota.limits(client, org_id) do
            {:ok, limits} ->
              assert is_number(limits.max_cpu_per_sandbox) or is_nil(limits.max_cpu_per_sandbox)

            {:error, %ExDaytona.Error{status: 401}} ->
              :jwt_gated_as_documented
          end

          # Metering (analytics API): auth model unconfirmed for API keys —
          # accept data or a documented auth gate, never a crash
          month_ago =
            DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.to_iso8601()

          now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

          case ExDaytona.Platform.usage_aggregated(client, org_id, month_ago, now_iso) do
            {:ok, usage} ->
              assert is_map(usage)

            {:error, %ExDaytona.Error{status: status}} when status in [401, 403] ->
              IO.puts("analytics metering is auth-gated for API keys (#{status})")
          end

          case ExDaytona.Platform.usage_per_sandbox(client, org_id, month_ago, now_iso) do
            {:ok, rows} -> assert is_list(rows)
            {:error, %ExDaytona.Error{status: status}} when status in [401, 403] -> :gated
          end

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

          # Structured log stream: separated stdout/stderr over the ws
          # multiplex protocol
          {:ok, mux_cmd} =
            ExDaytona.Session.run_async(
              session,
              "echo to-stdout; echo to-stderr 1>&2; sleep 1; echo late-stdout"
            )

          {:ok, log_stream} =
            ExDaytona.Session.open_log_stream(session, mux_cmd, idle_timeout: 30_000)

          assert {:ok, collected} = ExDaytona.LogStream.collect(log_stream, 30_000)
          assert collected.closed == :normal

          # Channel separation depends on the daemon: marker-emitting
          # daemons separate stdout/stderr; the current production daemon
          # streams unlabeled merged output ({:output, _} events).
          if collected.stdout != "" or collected.stderr != "" do
            assert collected.stdout =~ "to-stdout"
            assert collected.stdout =~ "late-stdout"
            assert collected.stderr =~ "to-stderr"
            refute collected.stdout =~ "to-stderr"
          else
            assert collected.output =~ "to-stdout"
            assert collected.output =~ "to-stderr"
            assert collected.output =~ "late-stdout"
          end

          # exit status stays a separate lookup
          assert {:ok, %{exit_code: 0}} = ExDaytona.Session.await(session, mux_cmd)

          # Owner-death cleanup: a stream owned by a dying process shuts down
          {:ok, owner_cmd} = ExDaytona.Session.run_async(session, "sleep 30")
          parent = self()

          owner =
            spawn(fn ->
              {:ok, stream} = ExDaytona.Session.open_log_stream(session, owner_cmd)
              send(parent, {:stream_opened, stream})

              receive do
                :die -> :ok
              end
            end)

          assert_receive {:stream_opened, orphan_stream}, 15_000
          orphan_ref = Process.monitor(orphan_stream)
          send(owner, :die)
          assert_receive {:DOWN, ^orphan_ref, :process, ^orphan_stream, _}, 5_000

          assert :ok = ExDaytona.Session.delete(session)

          # File system: full surface
          assert :ok = ExDaytona.FS.mkdir(sandbox, "/tmp/fs-live", mode: "755")
          assert :ok = ExDaytona.FS.write_file(sandbox, "/tmp/fs-live/a.txt", "TODO one")
          assert {:ok, %{size: size}} = ExDaytona.FS.stat(sandbox, "/tmp/fs-live/a.txt")
          assert size > 0
          assert {:ok, ["/tmp/fs-live/a.txt"]} = ExDaytona.FS.search(sandbox, "/tmp/fs-live", "*.txt")
          assert {:ok, [%{line: _}]} = ExDaytona.FS.grep(sandbox, "/tmp/fs-live", "TODO")
          assert {:ok, [%{success: true}]} = ExDaytona.FS.replace(sandbox, ["/tmp/fs-live/a.txt"], "TODO", "DONE")
          assert :ok = ExDaytona.FS.move(sandbox, "/tmp/fs-live/a.txt", "/tmp/fs-live/b.txt")
          assert {:ok, "DONE one"} = ExDaytona.FS.read_file(sandbox, "/tmp/fs-live/b.txt")
          assert :ok = ExDaytona.FS.delete(sandbox, "/tmp/fs-live", recursive: true)

          # Code execution: stateless + stateful
          assert {:ok, %{exit_code: 0, result: code_out}} =
                   ExDaytona.Sandbox.run_code(sandbox, "print(6*7)", language: "python")

          assert code_out =~ "42"

          assert {:ok, %{error: nil}} = ExDaytona.CodeInterpreter.run(sandbox, "counter = 41")

          assert {:ok, %{stdout: interp_out}} =
                   ExDaytona.CodeInterpreter.run(sandbox, "counter += 1\nprint(counter)")

          assert interp_out =~ "42"

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
          _ = ExDaytona.Secrets.delete(client, secret.id)
        end
      end
    end
  end
end
