defmodule ExDaytona.RedactTest do
  use TestCase, async: false

  import ExUnit.CaptureLog

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Redact

  # async: false — the telemetry test attaches a global handler.

  @canary "SUPERSECRETCANARY123"

  defp refute_canary(string) do
    refute string =~ @canary, "canary leaked in: #{String.slice(string, 0, 400)}"
  end

  describe "sensitive_key?/1" do
    test "matches credential-shaped names, atoms and strings, any casing" do
      for key <- [
            :api_key,
            :apiKey,
            "API-KEY",
            :authorization,
            :token,
            :sessionToken,
            :bearer_token,
            :secret,
            :clientSecret,
            :password,
            :credential,
            :access_key,
            :accessKey,
            "x-amz-security-token"
          ] do
        assert Redact.sensitive_key?(key), "expected #{inspect(key)} to be sensitive"
      end

      refute Redact.sensitive_key?(:name)
      refute Redact.sensitive_key?("content-type")
    end
  end

  describe "inspect/1 canaries" do
    test "ExDaytona.Client hides the api_key and the Tesla client" do
      {:ok, client} = Client.new(api_key: @canary)

      refute_canary(inspect(client))
      refute_canary(inspect(client, limit: :infinity, printable_limit: :infinity))
    end

    test "generated secret models redact their values" do
      refute_canary(inspect(%Model.CreateSecret{name: "db", value: @canary}))
      refute_canary(inspect(%Model.UpdateSecret{value: @canary}))

      refute_canary(inspect(%Model.ResolveSandboxSecrets200ResponseInner{env: "DB_PASSWORD", value: @canary}))

      # nonsecret fields stay visible for debugging
      assert inspect(%Model.CreateSecret{name: "db", value: @canary}) =~ "db"
    end

    test "generated credential-bearing models redact token/key fields" do
      refute_canary(inspect(%Model.SshAccessDto{token: @canary, sandboxId: "sb-1"}))
      refute_canary(inspect(%Model.ApiKeyResponse{name: "ci", value: @canary}))
      refute_canary(inspect(%Model.PortPreviewUrl{url: "https://x", token: @canary}))

      refute_canary(
        inspect(%Model.StorageAccessDto{
          accessKey: @canary,
          secret: @canary,
          sessionToken: @canary,
          bucket: "b"
        })
      )

      refute_canary(inspect(%Model.GitCloneRequest{url: "https://x", password: @canary}))
      refute_canary(inspect(%Model.WebhookAppPortalAccess{url: "https://x", token: @canary}))
    end

    test "facade credential structs redact" do
      refute_canary(
        inspect(%ExDaytona.Sandbox.SshAccess{
          token: @canary,
          ssh_command: "ssh #{@canary}@ssh.app.daytona.io"
        })
      )

      refute_canary(inspect(%ExDaytona.Sandbox.PreviewUrl{url: "https://x", token: @canary}))

      refute_canary(
        inspect(%ExDaytona.ObjectStorage.Access{
          access_key: @canary,
          secret: @canary,
          session_token: @canary,
          bucket: "b"
        })
      )
    end

    test "ExDaytona.Error deep-redacts details, headers, and URLs in messages" do
      error = %Error{
        status: 401,
        message: "auth failed for https://api.example.com/x?token=#{@canary}&kind=a",
        details: %{
          "Authorization" => "Bearer #{@canary}",
          "nested" => [%{"session_token" => @canary}],
          "keyword" => [api_key: @canary]
        },
        headers: [{"x-request-id", "req-1"}, {"authorization", "Bearer #{@canary}"}]
      }

      rendered = inspect(error, limit: :infinity, printable_limit: :infinity)
      refute_canary(rendered)
      assert rendered =~ "req-1"
    end
  end

  describe "deep/1 and scrub helpers" do
    test "sanitizes nested structures with case-insensitive string keys" do
      value = %{
        "TOKEN" => @canary,
        list: [%{secret: @canary}, "plain"],
        keyword: [password: @canary, ok: 1],
        keep: "visible"
      }

      sanitized = Redact.deep(value)
      refute_canary(inspect(sanitized, limit: :infinity))
      assert sanitized.keep == "visible"
      assert Keyword.get(sanitized.keyword, :ok) == 1
    end

    test "scrub_message masks signed query parameters but keeps the URL" do
      message = "GET https://proxy.example.com/p?signature=#{@canary}&port=3000 failed"
      scrubbed = Redact.scrub_message(message)

      refute_canary(scrubbed)
      assert scrubbed =~ "port=3000"
      assert scrubbed =~ "proxy.example.com"
    end
  end

  describe "diagnostic channels" do
    test "telemetry events for authenticated requests never carry the api key" do
      bypass = MockServer.setup()
      {:ok, client} = Client.new(api_key: @canary, base_url: MockServer.url(bypass), retry: false)

      MockServer.expect_get(bypass, "/sandbox/sb-1", 200, %{id: "sb-1"})

      parent = self()
      handler_id = "redact-canary-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [[:tesla, :request, :start], [:tesla, :request, :stop]],
        fn _event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _} = ExDaytona.Sandbox.get(client, "sb-1")

      assert_receive {:telemetry_event, _m1, metadata1}
      assert_receive {:telemetry_event, _m2, metadata2}

      refute_canary(inspect(metadata1, limit: :infinity, printable_limit: :infinity))
      refute_canary(inspect(metadata2, limit: :infinity, printable_limit: :infinity))
    end

    test "captured logs and error normalization never carry the canary" do
      bypass = MockServer.setup()
      {:ok, client} = Client.new(api_key: @canary, base_url: MockServer.url(bypass), retry: false)

      MockServer.expect_get(bypass, "/sandbox/sb-1", 500, %{message: "boom"})

      log =
        capture_log(fn ->
          assert {:error, %Error{} = error} = ExDaytona.Sandbox.get(client, "sb-1")
          refute_canary(inspect(error, limit: :infinity, printable_limit: :infinity))
        end)

      refute_canary(log)
    end

    test "exception paths render redacted" do
      {:ok, client} = Client.new(api_key: @canary)

      message =
        try do
          raise "operation failed for client: #{inspect(client)}"
        rescue
          e -> Exception.message(e)
        end

      refute_canary(message)
    end
  end
end
