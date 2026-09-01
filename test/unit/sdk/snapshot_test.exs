defmodule ExDaytona.SnapshotTest do
  use TestCase, async: true

  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Snapshot
  alias ExDaytona.Testing
  alias ExDaytona.WarmPool

  setup do
    {:ok, client: Testing.client()}
  end

  describe "create/3" do
    test "sends the snapshot settings and waits for active", %{client: client} do
      Testing.expect(:post, "/snapshots", fn env ->
        body = JSON.decode!(env.body)
        assert body["name"] == "base"
        assert body["cpu"] == 2
        assert body["imageName"] == "ubuntu:22.04"
        refute Map.has_key?(body, "buildInfo")

        {200, %{id: "snap-1", name: "base", state: "pending"}}
      end)

      Testing.stub(:get, "/snapshots/snap-1", %{id: "snap-1", name: "base", state: "active"})

      assert {:ok, %Model.SnapshotDto{state: "active"}} =
               Snapshot.create(client, "base", image_name: "ubuntu:22.04", cpu: 2, poll_interval: 5)

      Testing.verify!()
    end

    test "wait: false returns the created snapshot immediately", %{client: client} do
      Testing.expect(:post, "/snapshots", %{id: "snap-2", name: "fast", state: "building"})

      assert {:ok, %Model.SnapshotDto{id: "snap-2", state: "building"}} =
               Snapshot.create(client, "fast", wait: false)
    end

    test "image: builds the buildInfo from an Image", %{client: client} do
      image = ExDaytona.Image.from("alpine:3") |> ExDaytona.Image.run("apk add git")

      Testing.expect(:post, "/snapshots", fn env ->
        body = JSON.decode!(env.body)
        assert body["buildInfo"]["dockerfileContent"] =~ "FROM alpine:3"
        assert body["buildInfo"]["dockerfileContent"] =~ "RUN apk add git"

        {200, %{id: "snap-3", name: "built", state: "building"}}
      end)

      assert {:ok, _} = Snapshot.create(client, "built", image: image, wait: false)
    end

    test "rejects unknown options with the supported list", %{client: client} do
      assert {:error, %Error{message: message}} =
               Snapshot.create(client, "x", wrong_option: 1)

      assert message =~ "unknown snapshot option :wrong_option"
      assert message =~ ":image_name"
    end
  end

  describe "await_state/4" do
    test "fails fast on build errors with the provider's reason", %{client: client} do
      Testing.stub(:get, "/snapshots/snap-err", %{
        id: "snap-err",
        state: "build_failed",
        errorReason: "COPY failed"
      })

      assert {:error, %Error{message: message}} =
               Snapshot.await_state(client, "snap-err", "active", poll_interval: 5)

      assert message =~ "build_failed"
      assert message =~ "COPY failed"
    end

    test "times out with the last observed state", %{client: client} do
      Testing.stub(:get, "/snapshots/snap-slow", %{id: "snap-slow", state: "building"})

      assert {:error, %Error{message: message}} =
               Snapshot.await_state(client, "snap-slow", "active", timeout: 30, poll_interval: 5)

      assert message =~ "timed out"
      assert message =~ "building"
    end
  end

  describe "list/2" do
    test "normalizes pagination and maps source_sandbox_id", %{client: client} do
      Testing.expect(:get, "/snapshots", fn env ->
        assert env.query[:sourceSandboxId] == "sb-1"
        assert env.query[:limit] == 10

        {200, %{items: [%{id: "snap-1", state: "active"}], page: 1, total: 1, totalPages: 1}}
      end)

      assert {:ok, %{items: [%Model.SnapshotDto{id: "snap-1"}], page: 1, total: 1, total_pages: 1}} =
               Snapshot.list(client, source_sandbox_id: "sb-1", limit: 10)
    end
  end

  describe "lifecycle" do
    test "get, activate, deactivate, delete", %{client: client} do
      Testing.expect(:get, "/snapshots/snap-1", %{id: "snap-1", state: "inactive"})
      Testing.expect(:post, "/snapshots/snap-1/activate", %{id: "snap-1", state: "active"})
      Testing.expect(:post, "/snapshots/snap-1/deactivate", 204)
      Testing.expect(:delete, "/snapshots/snap-1", 200)

      assert {:ok, %Model.SnapshotDto{state: "inactive"}} = Snapshot.get(client, "snap-1")
      assert {:ok, %Model.SnapshotDto{state: "active"}} = Snapshot.activate(client, "snap-1")
      assert :ok = Snapshot.deactivate(client, "snap-1")
      assert :ok = Snapshot.delete(client, "snap-1")

      Testing.verify!()
    end
  end

  describe "build logs" do
    test "build_logs returns the raw text", %{client: client} do
      Testing.expect(:get, "/snapshots/snap-1/build-logs", {200, "step 1: FROM ubuntu\n"})

      assert {:ok, "step 1: FROM ubuntu\n"} = Snapshot.build_logs(client, "snap-1")
    end

    test "stream_build_logs follows via the client's stream transport", %{client: client} do
      Testing.script_http_stream(chunks: ["chunk-a", "chunk-b"])
      parent = self()

      assert :ok =
               Snapshot.stream_build_logs(client, "snap-1", fn chunk ->
                 send(parent, {:log, chunk})
               end)

      assert_received {:log, "chunk-a"}
      assert_received {:log, "chunk-b"}
    end
  end

  describe "build/4" do
    test "without :log it creates from a raw Dockerfile and awaits active", %{client: client} do
      Testing.expect(:post, "/snapshots", fn env ->
        assert JSON.decode!(env.body)["buildInfo"]["dockerfileContent"] == "FROM scratch\n"
        {200, %{id: "snap-raw", name: "raw", state: "building"}}
      end)

      Testing.stub(:get, "/snapshots/snap-raw", %{id: "snap-raw", state: "active"})

      assert {:ok, %Model.SnapshotDto{state: "active"}} =
               Snapshot.build(client, "raw", "FROM scratch\n", poll_interval: 5)
    end

    test "a failed create surfaces without polling", %{client: client} do
      Testing.expect(:post, "/snapshots", {400, %{message: "name taken"}})

      assert {:error, %Error{status: 400}} = Snapshot.build(client, "dup", "FROM scratch\n")
    end
  end

  describe "build/4 with MockServer" do
    # The full build flow — create, follow build logs over real chunked
    # HTTP, poll to active — against the Bandit-backed mock server.
    test "creates, streams logs, and awaits active" do
      bypass = MockServer.setup()

      {:ok, client} =
        ExDaytona.Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass), retry: false)

      MockServer.expect_once(bypass, "POST", "/snapshots", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "snap-b", name: "base", state: "building"}))
      end)

      MockServer.expect_once(bypass, "GET", "/snapshots/snap-b/build-logs", fn conn ->
        assert conn.query_string =~ "follow=true"
        Plug.Conn.resp(conn, 200, "step 1/2 : FROM ubuntu\nstep 2/2 : RUN true\n")
      end)

      MockServer.expect(bypass, "GET", "/snapshots/snap-b", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "snap-b", name: "base", state: "active"}))
      end)

      parent = self()

      assert {:ok, %Model.SnapshotDto{id: "snap-b", state: "active"}} =
               Snapshot.build(client, "base", ExDaytona.Image.from("ubuntu:22.04"),
                 log: fn chunk -> send(parent, {:build_log, chunk}) end,
                 poll_interval: 10
               )

      assert_receive {:build_log, chunk}, 2_000
      assert chunk =~ "step 1/2"
    end
  end

  describe "WarmPool" do
    test "create requires snapshot and size and sends them", %{client: client} do
      Testing.expect(:post, "/warm-pools", fn env ->
        body = JSON.decode!(env.body)
        assert body == %{"snapshot" => "base", "pool" => 5, "target" => "us"}

        {201, %{id: "wp-1", snapshot: "base", pool: 5, currentSize: 0}}
      end)

      assert {:ok, %Model.WarmPool{id: "wp-1", pool: 5}} =
               WarmPool.create(client, snapshot: "base", size: 5, target: "us")

      assert_raise KeyError, fn -> WarmPool.create(client, snapshot: "base") end
    end

    test "list, resize, delete", %{client: client} do
      Testing.expect(:get, "/warm-pools", [%{id: "wp-1", pool: 5}])

      Testing.expect(:patch, "/warm-pools/wp-1", fn env ->
        assert JSON.decode!(env.body) == %{"pool" => 10}
        {200, %{id: "wp-1", pool: 10}}
      end)

      Testing.expect(:delete, "/warm-pools/wp-1", 204)

      assert {:ok, [%Model.WarmPool{id: "wp-1"}]} = WarmPool.list(client)
      assert {:ok, %Model.WarmPool{pool: 10}} = WarmPool.resize(client, "wp-1", 10)
      assert :ok = WarmPool.delete(client, "wp-1")

      Testing.verify!()
    end
  end
end
