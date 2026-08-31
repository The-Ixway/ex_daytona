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

  describe "typed operations (customize per SDK)" do
    # CUSTOMIZE(live): replace with a cheap read operation from this SDK and
    # delete the skip tag, e.g.:
    #
    #   assert {:ok, %YourSDK.Model.Thing{}} =
    #            YourSDK.Api.Things.get_thing(live_client(ctx), "id")
    #
    # This is the test that catches spec-vs-server decode mismatches.
    @tag :skip
    test "a basic read operation succeeds and decodes into a typed struct", _ctx do
      flunk("customize with a real operation from this SDK, then remove @tag :skip")
    end

    # CUSTOMIZE(live): call an operation that takes query parameters and assert the
    # server honored them (e.g. a limit/page size reflected in the result),
    # then delete the skip tag. Proves query params survive the request
    # builder + middleware stack against a real server.
    @tag :skip
    test "query parameters are transmitted and honored", _ctx do
      flunk("customize with a real operation from this SDK, then remove @tag :skip")
    end

    # CUSTOMIZE(live): trigger a spec-declared error status (e.g. a 400 from an
    # invalid payload) and assert its shape, then delete the skip tag.
    # Reminder: spec-mapped error statuses return `{:ok, error_struct}` —
    # an openapi-generator convention — NOT `{:error, _}`.
    @tag :skip
    test "a spec-declared error status decodes into its error model", _ctx do
      flunk("customize with a real operation from this SDK, then remove @tag :skip")
    end
  end
end
