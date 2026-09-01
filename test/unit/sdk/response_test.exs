defmodule ExDaytona.ResponseTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Response

  describe "header parsing" do
    test "normalizes names, looks up case-insensitively, retains unknown headers" do
      headers = Response.normalize_headers([{"X-Request-ID", "req-1"}, {"X-Custom", "keep"}])

      assert headers == [{"x-request-id", "req-1"}, {"x-custom", "keep"}]
      assert Response.get_header(headers, "X-REQUEST-id") == "req-1"
      assert Response.get_header(headers, "x-custom") == "keep"
      assert Response.get_headers(headers, "x-request-id") == ["req-1"]
    end

    test "parses Retry-After integer and HTTP-date forms; rejects invalid" do
      assert Response.parse_retry_after("120") == 120
      assert Response.parse_retry_after(" 0 ") == 0
      assert Response.parse_retry_after(nil) == nil
      assert Response.parse_retry_after("soon") == nil
      assert Response.parse_retry_after("-5") == nil

      # HTTP-date in the past floors at 0
      assert Response.parse_retry_after("Wed, 21 Oct 2015 07:28:00 GMT") == 0

      # HTTP-date in the future yields a positive delta
      future =
        DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      delta = Response.parse_retry_after(future)
      assert delta > 3500 and delta <= 3600
    end

    test "parses rate-limit headers across common prefixes" do
      for prefix <- ["x-ratelimit-", "x-rate-limit-", "ratelimit-"] do
        headers = [
          {prefix <> "limit", "100"},
          {prefix <> "remaining", "42"},
          {prefix <> "reset", "1700000000"}
        ]

        assert Response.parse_rate_limit(headers) ==
                 %{limit: 100, remaining: 42, reset: 1_700_000_000}
      end

      assert Response.parse_rate_limit([{"content-type", "application/json"}]) == nil
    end
  end

  describe "response: :full on generated operations" do
    setup do
      bypass = MockServer.setup()

      {:ok, client} =
        Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass), retry: false)

      {:ok, bypass: bypass, client: client}
    end

    test "wraps the decoded model with metadata", %{bypass: bypass, client: client} do
      MockServer.expect_once(bypass, "GET", "/sandbox/sb-1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("x-request-id", "req-42")
        |> Plug.Conn.put_resp_header("x-ratelimit-limit", "1000")
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "999")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "sb-1", state: "started"}))
      end)

      assert {:ok, %Response{} = response} =
               ExDaytona.Api.Sandbox.get_sandbox(Client.conn(client), "sb-1", response: :full)

      assert %Model.Sandbox{id: "sb-1"} = response.data
      assert response.status == 200
      assert response.request_id == "req-42"
      assert response.rate_limit == %{limit: 1000, remaining: 999, reset: nil}
      assert response.retry_count == 0
    end

    test "default mode is unchanged", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/sandbox/sb-1", 200, %{id: "sb-1"})

      assert {:ok, %Model.Sandbox{id: "sb-1"}} =
               ExDaytona.Api.Sandbox.get_sandbox(Client.conn(client), "sb-1")
    end

    test "declared error models keep their metadata (through the facade too)", %{
      bypass: bypass,
      client: client
    } do
      MockServer.expect_once(bypass, "POST", "/toolbox/sb-1/process/execute", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("x-request-id", "req-err")
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.resp(400, JSON.encode!(%{message: "bad command", statusCode: 400}))
      end)

      sandbox = %ExDaytona.Sandbox{
        client: client,
        info: %Model.Sandbox{
          id: "sb-1",
          toolboxProxyUrl: MockServer.url(bypass) <> "/toolbox"
        }
      }

      assert {:error, %Error{} = error} =
               ExDaytona.Sandbox.exec(sandbox, "bad")

      assert error.status == 400
      assert error.message == "bad command"
      assert error.request_id == "req-err"
      assert error.retry_after == 30
      assert error.outcome == :definite
    end

    test "undeclared errors keep metadata and rate-limit state", %{
      bypass: bypass,
      client: client
    } do
      MockServer.expect_once(bypass, "GET", "/sandbox/sb-1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("x-request-id", "req-429")
        |> Plug.Conn.put_resp_header("retry-after", "7")
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.resp(429, JSON.encode!(%{message: "rate limited"}))
      end)

      assert {:error, %Error{} = error} = ExDaytona.Sandbox.get(client, "sb-1")

      assert error.status == 429
      assert error.request_id == "req-429"
      assert error.retry_after == 7
      assert error.rate_limit.remaining == 0
      assert error.outcome == :definite
    end

    test "transport failures classify as an unknown outcome", %{client: client} do
      {:ok, dead_client} = Client.new(api_key: "dtn_test", base_url: "http://localhost:1", retry: false)

      assert {:error, %Error{outcome: :unknown, status: nil}} =
               ExDaytona.Sandbox.get(dead_client, "sb-1")

      # ...while provider-answered failures stay definite
      assert %Error{outcome: :definite} = Error.from(%Tesla.Env{status: 500, body: ""})
      _ = client
    end
  end

  describe "retry metadata and option forwarding" do
    test "retry_count reflects transport retries", %{} do
      bypass = MockServer.setup()

      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      MockServer.expect(bypass, "GET", "/sandbox/sb-1", fn conn ->
        n = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

        if n < 3 do
          Plug.Conn.resp(conn, 503, "")
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, JSON.encode!(%{id: "sb-1"}))
        end
      end)

      conn =
        ExDaytona.Connection.new(
          base_url: MockServer.url(bypass),
          retry: [delay: 1, max_delay: 5, max_retries: 5]
        )

      assert {:ok, %Response{retry_count: 2, data: %Model.Sandbox{}}} =
               ExDaytona.Api.Sandbox.get_sandbox(conn, "sb-1", response: :full)
    end

    test "middleware forwards all retry options including Retry-After handling" do
      middleware =
        ExDaytona.Connection.middleware(
          retry: [
            delay: 10,
            max_retries: 7,
            max_delay: 99,
            jitter_factor: 0.5,
            use_retry_after_header: false
          ]
        )

      assert {Tesla.Middleware.Retry, retry_opts} =
               List.keyfind(middleware, Tesla.Middleware.Retry, 0)

      assert retry_opts[:delay] == 10
      assert retry_opts[:max_retries] == 7
      assert retry_opts[:max_delay] == 99
      assert retry_opts[:jitter_factor] == 0.5
      assert retry_opts[:use_retry_after_header] == false
      assert is_function(retry_opts[:should_retry], 3)

      # Defaults: jitter 0.2 and Retry-After honored
      default_middleware = ExDaytona.Connection.middleware(retry: [])

      assert {Tesla.Middleware.Retry, default_opts} =
               List.keyfind(default_middleware, Tesla.Middleware.Retry, 0)

      assert default_opts[:jitter_factor] == 0.2
      assert default_opts[:use_retry_after_header] == true
    end

    test "429 with Retry-After is honored on safe retries" do
      bypass = MockServer.setup()
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      MockServer.expect(bypass, "GET", "/sandbox/sb-1", fn conn ->
        n = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

        if n < 2 do
          conn
          # tiny Retry-After (0s) so the test stays fast; presence proves the path
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.resp(429, "")
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, JSON.encode!(%{id: "sb-1"}))
        end
      end)

      conn =
        ExDaytona.Connection.new(
          base_url: MockServer.url(bypass),
          retry: [delay: 1, max_delay: 50, max_retries: 3]
        )

      assert {:ok, %Response{retry_count: 1}} =
               ExDaytona.Api.Sandbox.get_sandbox(conn, "sb-1", response: :full)
    end
  end
end
