defmodule ExDaytona.TelemetryTest do
  use TestCase, async: true

  alias ExDaytona.Sandbox
  alias ExDaytona.Testing

  # Telemetry handlers are global; each test uses a unique sandbox id and
  # matches its own metadata, so concurrent tests don't interfere.

  defp attach_events(events) do
    parent = self()
    handler_id = "ex-daytona-telemetry-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "sandbox exec emits a start/stop span with outcome and exit code" do
    attach_events([
      [:ex_daytona, :sandbox, :exec, :start],
      [:ex_daytona, :sandbox, :exec, :stop]
    ])

    sandbox = Testing.sandbox(%{id: "sb-tel-exec"})
    Testing.expect(:post, "/process/execute", %{exitCode: 0, result: "hi"})

    assert {:ok, %{exit_code: 0}} = Sandbox.exec(sandbox, "echo hi")

    assert_receive {:telemetry, [:ex_daytona, :sandbox, :exec, :start], %{system_time: _}, %{sandbox_id: "sb-tel-exec"}}

    assert_receive {:telemetry, [:ex_daytona, :sandbox, :exec, :stop], %{duration: duration},
                    %{sandbox_id: "sb-tel-exec"} = metadata}

    assert is_integer(duration)
    assert metadata.outcome == :ok
    assert metadata.exit_code == 0
    assert metadata.error_code == nil
  end

  test "a failed operation stops with outcome :error and the status" do
    attach_events([[:ex_daytona, :sandbox, :exec, :stop]])

    sandbox = Testing.sandbox(%{id: "sb-tel-fail"})
    Testing.expect(:post, "/process/execute", {500, %{message: "boom"}})

    assert {:error, _} = Sandbox.exec(sandbox, "echo hi")

    assert_receive {:telemetry, [:ex_daytona, :sandbox, :exec, :stop], _measurements,
                    %{sandbox_id: "sb-tel-fail"} = metadata}

    assert metadata.outcome == :error
    assert metadata.error_status == 500
  end

  test "sandbox delete emits its span" do
    attach_events([[:ex_daytona, :sandbox, :delete, :stop]])

    sandbox = Testing.sandbox(%{id: "sb-tel-del"})
    Testing.expect(:delete, "/sandbox/sb-tel-del", Testing.sandbox_json(%{id: "sb-tel-del"}))

    assert :ok = Sandbox.delete(sandbox)

    assert_receive {:telemetry, [:ex_daytona, :sandbox, :delete, :stop], _measurements,
                    %{sandbox_id: "sb-tel-del", outcome: :ok}}
  end

  test "sandbox create's stop metadata carries the created id" do
    attach_events([[:ex_daytona, :sandbox, :create, :stop]])

    client = Testing.client()
    Testing.expect(:post, "/sandbox", Testing.sandbox_json(%{id: "sb-tel-create"}))
    Testing.stub(:get, "/sandbox/sb-tel-create", Testing.sandbox_json(%{id: "sb-tel-create"}))

    assert {:ok, _sandbox} = Sandbox.create(client, name: "tel", poll_interval: 5)

    assert_receive {:telemetry, [:ex_daytona, :sandbox, :create, :stop], _measurements,
                    %{sandbox_id: "sb-tel-create", outcome: :ok}}
  end

  test "fs download emits byte counts" do
    attach_events([[:ex_daytona, :fs, :download, :stop]])

    sandbox = Testing.sandbox(%{id: "sb-tel-dl"})
    Testing.script_http_stream(chunks: ["12345", "678"])

    assert {:ok, %{bytes: 8}} =
             ExDaytona.FS.download_stream(sandbox, "/f.bin", fn _chunk -> :ok end)

    assert_receive {:telemetry, [:ex_daytona, :fs, :download, :stop], _measurements,
                    %{sandbox_id: "sb-tel-dl", outcome: :ok, bytes: 8}}
  end

  test "session run emits with session metadata" do
    attach_events([[:ex_daytona, :session, :run, :stop]])

    sandbox = Testing.sandbox(%{id: "sb-tel-session"})
    session = %ExDaytona.Session{sandbox: sandbox, id: "sess-1"}

    Testing.expect(:post, "/process/session/sess-1/exec", %{
      cmdId: "cmd-1",
      exitCode: 0,
      output: "ok"
    })

    assert {:ok, %{exit_code: 0}} = ExDaytona.Session.run(session, "true")

    assert_receive {:telemetry, [:ex_daytona, :session, :run, :stop], _measurements,
                    %{sandbox_id: "sb-tel-session", session_id: "sess-1", exit_code: 0}}
  end
end
