defmodule ExDaytona.WebhooksPlugTest do
  use TestCase, async: true

  import Plug.Test
  import Plug.Conn

  alias ExDaytona.Webhooks

  @secret_key :crypto.strong_rand_bytes(24)
  @secret "whsec_" <> Base.encode64(@secret_key)
  @path "/webhooks/daytona"

  defmodule RecordingHandler do
    @behaviour ExDaytona.Webhooks.Handler

    @impl true
    def handle_event(event, conn) do
      send(self(), {:handled, event, conn.request_path})
      :ok
    end
  end

  defp sign(payload, id, timestamp, key) do
    signature = :crypto.mac(:hmac, :sha256, key, "#{id}.#{timestamp}.#{payload}")
    "v1," <> Base.encode64(signature)
  end

  defp signed_conn(payload, opts \\ []) do
    now = Keyword.get(opts, :timestamp, System.system_time(:second))
    id = Keyword.get(opts, :id, "msg_1")
    key = Keyword.get(opts, :key, @secret_key)
    path = Keyword.get(opts, :path, @path)
    method = Keyword.get(opts, :method, :post)

    conn(method, path, payload)
    |> put_req_header("svix-id", id)
    |> put_req_header("svix-timestamp", "#{now}")
    |> put_req_header("svix-signature", sign(payload, id, now, key))
  end

  defp run(conn, opts) do
    defaults = [at: @path, secret: @secret, handler: RecordingHandler]
    plug_opts = Webhooks.Plug.init(Keyword.merge(defaults, opts))
    Webhooks.Plug.call(conn, plug_opts)
  end

  test "a valid delivery dispatches the decoded event and answers 204" do
    payload = JSON.encode!(%{type: "sandbox.created", data: %{id: "sb-1"}})

    conn = run(signed_conn(payload), [])

    assert conn.status == 204
    assert conn.halted
    assert_received {:handled, %{"type" => "sandbox.created"}, @path}
  end

  test "requests to other paths pass through untouched" do
    conn = run(conn(:post, "/api/other", "{}"), [])

    refute conn.halted
    assert conn.status == nil
  end

  test "non-POST requests at the path answer 405" do
    conn = run(signed_conn("{}", method: :get), [])

    assert conn.status == 405
    refute_received {:handled, _event, _path}
  end

  test "a bad signature answers 400 without invoking the handler" do
    conn = run(signed_conn("{}", key: :crypto.strong_rand_bytes(24)), [])

    assert conn.status == 400
    refute_received {:handled, _event, _path}
  end

  test "missing signature headers answer 400" do
    conn = run(conn(:post, @path, "{}"), [])

    assert conn.status == 400
  end

  test "a stale timestamp answers 400" do
    stale = System.system_time(:second) - 10_000

    conn = run(signed_conn("{}", timestamp: stale), [])

    assert conn.status == 400
  end

  test "an oversized body answers 413" do
    payload = String.duplicate("x", 200)

    conn = run(signed_conn(payload), max_body_bytes: 100)

    assert conn.status == 413
  end

  test "handler failure answers 500 so the provider retries" do
    conn = run(signed_conn("{}"), handler: fn _event -> {:error, :later} end)

    assert conn.status == 500
  end

  test "a raising handler answers 500" do
    {conn, log} =
      ExUnit.CaptureLog.with_log(fn ->
        run(signed_conn("{}"), handler: fn _event -> raise "boom" end)
      end)

    assert conn.status == 500
    assert log =~ "handler raised"
  end

  test "MFA secrets resolve at request time and arity-2 fun handlers get the conn" do
    parent = self()

    conn =
      run(signed_conn(~s({"n":1})),
        secret: {__MODULE__, :lookup_secret, []},
        handler: fn event, conn ->
          send(parent, {:seen, event, conn.method})
          :ok
        end
      )

    assert conn.status == 204
    assert_received {:seen, %{"n" => 1}, "POST"}
  end

  test "zero-arity fun secrets and arity-1 fun handlers work" do
    parent = self()

    conn =
      run(signed_conn(~s({"a":1})),
        secret: fn -> @secret end,
        handler: fn event ->
          send(parent, {:evt, event})
          :ok
        end
      )

    assert conn.status == 204
    assert_received {:evt, %{"a" => 1}}
  end

  test "{module, function} handlers are applied with event and conn" do
    conn = run(signed_conn(~s({"mf":true})), handler: {__MODULE__, :record_mf})

    assert conn.status == 204
    assert_received {:mf_handled, %{"mf" => true}}
  end

  test "without :at every request is handled" do
    conn = run(signed_conn("{}", path: "/anything"), at: nil)

    assert conn.status == 204
  end

  test "init validates secret and handler shapes" do
    assert_raise ArgumentError, ~r/:secret/, fn ->
      Webhooks.Plug.init(secret: 123, handler: RecordingHandler)
    end

    assert_raise ArgumentError, ~r/:handler/, fn ->
      Webhooks.Plug.init(secret: @secret, handler: "nope")
    end
  end

  def lookup_secret, do: @secret

  def record_mf(event, _conn) do
    send(self(), {:mf_handled, event})
    :ok
  end
end
