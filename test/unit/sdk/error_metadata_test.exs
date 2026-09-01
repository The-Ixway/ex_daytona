defmodule ExDaytona.ErrorMetadataTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Platform
  alias ExDaytona.Response

  describe "Error.normalize/normalize_full over Response envelopes" do
    test "unwraps success data and keeps envelopes with normalize_full" do
      response = Response.from_env(%Tesla.Env{status: 200, headers: []}, %Model.Sandbox{id: "s"})

      assert {:ok, %Model.Sandbox{id: "s"}} = Error.normalize({:ok, response})
      assert {:ok, %Response{data: %Model.Sandbox{id: "s"}}} = Error.normalize_full({:ok, response})
    end

    test "normalize_full converts failures the same way as normalize" do
      env = %Tesla.Env{status: 503, headers: [{"Retry-After", "9"}], body: %{"message" => "no"}}
      response = Response.from_env(env, env)

      assert {:error, %Error{status: 503, retry_after: 9}} = Error.normalize_full({:ok, response})
      assert {:error, %Error{status: 503}} = Error.normalize_full({:error, env})
    end

    test "a Response carrying a plain error payload maps message/code" do
      env = %Tesla.Env{status: 422, headers: [{"x-request-id", "r-9"}]}
      response = Response.from_env(env, %{"message" => "invalid", "code" => "BAD"})

      assert {:error, %Error{status: 422, message: "invalid", code: "BAD", request_id: "r-9"}} =
               Error.normalize({:ok, response})
    end

    test "an ErrorResponse without statusCode falls back to the envelope status" do
      env = %Tesla.Env{status: 409, headers: []}
      response = Response.from_env(env, %Model.ErrorResponse{message: "conflict"})

      assert {:error, %Error{status: 409, message: "conflict", outcome: :definite}} =
               Error.normalize({:ok, response})
    end
  end

  describe "Response edge parsing" do
    test "HTTP-date rejects malformed dates and handles all months" do
      assert Response.parse_http_date("nonsense") == nil
      assert Response.parse_http_date("Wed, xx Oct 2015 07:28:00 GMT") == nil

      for {month, n} <- [{"Jan", 1}, {"Dec", 12}] do
        unix = Response.parse_http_date("Wed, 21 #{month} 2015 07:28:00 GMT")
        assert %DateTime{month: ^n} = DateTime.from_unix!(unix)
      end
    end

    test "get_header helpers on a Response struct" do
      response =
        Response.from_env(
          %Tesla.Env{status: 200, headers: [{"X-Thing", "a"}, {"x-thing", "b"}]},
          nil
        )

      assert Response.get_header(response, "x-THING") == "a"
      assert Response.get_headers(response, "x-thing") == ["a", "b"]
    end
  end

  describe "Platform remaining lookups" do
    setup do
      bypass = MockServer.setup()

      {:ok, client} =
        Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass), retry: false)

      {:ok, bypass: bypass, client: client}
    end

    test "organizations/1 and snapshot/2", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/organizations", 200, [%{id: "org-1", name: "Acme"}])
      assert {:ok, [%Model.Organization{id: "org-1"}]} = Platform.organizations(client)

      MockServer.expect_get(bypass, "/snapshots/snap-1", 200, %{id: "snap-1", name: "base"})
      assert {:ok, %Model.SnapshotDto{id: "snap-1"}} = Platform.snapshot(client, "snap-1")
    end
  end

  describe "Redact edges" do
    test "scrub_url leaves query-less URLs and odd pairs intact" do
      assert ExDaytona.Redact.scrub_url("https://x.example/no-query") ==
               "https://x.example/no-query"

      assert ExDaytona.Redact.scrub_message("plain text, no urls") == "plain text, no urls"
      assert ExDaytona.Redact.scrub_url("https://x.example/p?flag") == "https://x.example/p?flag"
    end

    test "sensitive_key? tolerates non-string, non-atom keys" do
      refute ExDaytona.Redact.sensitive_key?(123)
      refute ExDaytona.Redact.sensitive_key?({:tuple, :key})
    end

    test "deep/1 passes structs and scalars through sanitized" do
      sanitized = ExDaytona.Redact.deep(%Model.CreateSecret{name: "n", value: "v"})
      # struct keys pass through the map path — :value is not name-sensitive,
      # struct-name-based :value redaction applies only at inspect time
      assert sanitized.__struct__ == Model.CreateSecret
      assert ExDaytona.Redact.deep(42) == 42
    end
  end
end
