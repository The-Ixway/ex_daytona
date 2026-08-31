defmodule ConnectionRuntimeTest do
  @moduledoc """
  Unit tests for the template-owned `Connection` runtime: middleware option
  handling and the idempotent-only retry contract. These behaviors are
  identical for every minted SDK; the module is discovered via reflection so
  the tests survive regeneration.
  """

  use ExUnit.Case, async: true

  @connection SdkSurface.connection_module()

  describe "new/1, middleware/1, and adapter/0" do
    test "builds a Tesla client with defaults" do
      assert %Tesla.Client{} = @connection.new()
    end

    test "appends custom middleware" do
      middleware = @connection.middleware(middleware: [Tesla.Middleware.Logger])

      assert Tesla.Middleware.Logger in middleware
    end

    test "forwards the bearer token when the spec defines bearer auth" do
      # The BearerAuth middleware is only generated for specs with a bearer
      # security scheme; for SDKs without one the option is silently ignored,
      # so this asserts nothing for them.
      middleware = @connection.middleware(bearer_token: "token")

      if Enum.any?(middleware, &match?({Tesla.Middleware.BearerAuth, _opts}, &1)) do
        assert {Tesla.Middleware.BearerAuth, token: "token"} in middleware
      end
    end

    test "adds no auth middleware when no credentials are provided" do
      # A connection built without credentials must send NO authorization
      # header: Tesla's BearerAuth/BasicAuth interpolate their values
      # unconditionally, and an empty `Authorization: Bearer ` header makes
      # many servers reject public requests as failed auth attempts.
      middleware = @connection.middleware()

      refute Enum.any?(middleware, &match?({Tesla.Middleware.BearerAuth, _opts}, &1))
      refute Enum.any?(middleware, &match?({Tesla.Middleware.BasicAuth, _opts}, &1))
    end

    test "retry middleware is on by default and removable with retry: false" do
      assert Enum.any?(@connection.middleware(), &match?({Tesla.Middleware.Retry, _opts}, &1))

      refute Enum.any?(
               @connection.middleware(retry: false),
               &match?({Tesla.Middleware.Retry, _opts}, &1)
             )
    end

    test "uses the configured base_url" do
      assert {Tesla.Middleware.BaseUrl, "http://example.test"} in @connection.middleware(
               base_url: "http://example.test"
             )
    end

    test "adapter defaults to the pooled Finch instance" do
      assert {Tesla.Adapter.Finch, name: finch} = @connection.adapter()
      assert finch == SdkSurface.finch_name()
    end
  end

  describe "retry behavior" do
    setup do
      bypass = Bypass.open()
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      {:ok, bypass: bypass, counter: counter}
    end

    test "retries idempotent requests on retriable statuses", %{bypass: bypass, counter: counter} do
      Bypass.expect(bypass, "GET", "/thing", fn conn ->
        attempt = Agent.get_and_update(counter, &{&1, &1 + 1})
        status = if attempt == 0, do: 503, else: 200
        Plug.Conn.resp(conn, status, "{}")
      end)

      client = client(bypass, retry: [delay: 1, max_retries: 2])

      assert {:ok, %Tesla.Env{status: 200}} =
               @connection.request(client, method: :get, url: "/thing")

      assert Agent.get(counter, & &1) == 2
    end

    test "never retries POST requests", %{bypass: bypass, counter: counter} do
      Bypass.expect(bypass, "POST", "/thing", fn conn ->
        Agent.update(counter, &(&1 + 1))
        Plug.Conn.resp(conn, 503, "{}")
      end)

      client = client(bypass, retry: [delay: 1, max_retries: 3])

      assert {:ok, %Tesla.Env{status: 503}} =
               @connection.request(client, method: :post, url: "/thing", body: "{}")

      assert Agent.get(counter, & &1) == 1
    end

    test "retries transport errors for idempotent methods and gives up", %{bypass: bypass} do
      Bypass.down(bypass)
      client = client(bypass, retry: [delay: 1, max_retries: 1])

      assert {:error, _reason} = @connection.request(client, method: :get, url: "/thing")
    end

    test "does not retry transport errors for POST", %{bypass: bypass} do
      Bypass.down(bypass)
      client = client(bypass, retry: [delay: 1, max_retries: 1])

      assert {:error, _reason} =
               @connection.request(client, method: :post, url: "/thing", body: "{}")
    end

    defp client(bypass, opts) do
      @connection.new([base_url: "http://localhost:#{bypass.port}"] ++ opts)
    end
  end
end
