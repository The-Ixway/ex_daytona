defmodule ExDaytona.WebhooksTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Webhooks

  describe "setup" do
    setup do
      bypass = MockServer.setup()

      {:ok, client} =
        Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass), retry: false)

      {:ok, bypass: bypass, client: client}
    end

    test "initialize/2 returns the status", %{bypass: bypass, client: client} do
      MockServer.expect_post(bypass, "/webhooks/organizations/org-1/initialize", 201, %{
        organizationId: "org-1",
        svixApplicationId: "app_1"
      })

      assert {:ok, %Model.WebhookInitializationStatus{svixApplicationId: "app_1"}} =
               Webhooks.initialize(client, "org-1")
    end

    test "portal/2 returns the app portal access", %{bypass: bypass, client: client} do
      MockServer.expect_post(bypass, "/webhooks/organizations/org-1/app-portal-access", 200, %{
        url: "https://app.svix.com/portal#key",
        token: "tok"
      })

      assert {:ok, %{url: "https://app.svix.com/portal#key", token: "tok"}} =
               Webhooks.portal(client, "org-1")
    end

    test "refresh_endpoints/2 returns :ok", %{bypass: bypass, client: client} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/webhooks/organizations/org-1/refresh-endpoints",
        fn conn -> Plug.Conn.resp(conn, 204, "") end
      )

      assert :ok = Webhooks.refresh_endpoints(client, "org-1")
    end
  end

  describe "verify/4" do
    @secret_key :crypto.strong_rand_bytes(24)
    @secret "whsec_" <> Base.encode64(@secret_key)

    defp sign(payload, id, timestamp, key \\ @secret_key) do
      signature = :crypto.mac(:hmac, :sha256, key, "#{id}.#{timestamp}.#{payload}")
      "v1," <> Base.encode64(signature)
    end

    test "accepts a valid Svix-signed delivery and decodes the payload" do
      payload = JSON.encode!(%{type: "sandbox.created", data: %{id: "sb-1"}})
      now = 1_756_680_000

      headers = [
        {"svix-id", "msg_1"},
        {"svix-timestamp", "#{now}"},
        {"svix-signature", sign(payload, "msg_1", now)}
      ]

      assert {:ok, %{"type" => "sandbox.created", "data" => %{"id" => "sb-1"}}} =
               Webhooks.verify(payload, headers, @secret, now: now)
    end

    test "accepts the Standard Webhooks header aliases and a map of headers" do
      payload = ~s({"ok":true})
      now = 1_756_680_000

      headers = %{
        "Webhook-Id" => "msg_2",
        "Webhook-Timestamp" => "#{now}",
        "Webhook-Signature" => sign(payload, "msg_2", now)
      }

      assert {:ok, %{"ok" => true}} = Webhooks.verify(payload, headers, @secret, now: now)
    end

    test "accepts a signature list containing older versions" do
      payload = ~s({"ok":true})
      now = 1_756_680_000
      header = "v2,bogus " <> sign(payload, "msg_3", now)

      headers = [
        {"svix-id", "msg_3"},
        {"svix-timestamp", "#{now}"},
        {"svix-signature", header}
      ]

      assert {:ok, _} = Webhooks.verify(payload, headers, @secret, now: now)
    end

    test "rejects a tampered payload" do
      payload = ~s({"amount":100})
      now = 1_756_680_000
      signature = sign(payload, "msg_4", now)

      headers = [
        {"svix-id", "msg_4"},
        {"svix-timestamp", "#{now}"},
        {"svix-signature", signature}
      ]

      assert {:error, %Error{message: message}} =
               Webhooks.verify(~s({"amount":999999}), headers, @secret, now: now)

      assert message =~ "signature mismatch"
    end

    test "rejects a signature made with the wrong secret" do
      payload = ~s({"ok":true})
      now = 1_756_680_000
      wrong_key = :crypto.strong_rand_bytes(24)

      headers = [
        {"svix-id", "msg_5"},
        {"svix-timestamp", "#{now}"},
        {"svix-signature", sign(payload, "msg_5", now, wrong_key)}
      ]

      assert {:error, %Error{message: message}} =
               Webhooks.verify(payload, headers, @secret, now: now)

      assert message =~ "signature mismatch"
    end

    test "rejects a stale timestamp" do
      payload = ~s({"ok":true})
      sent_at = 1_756_680_000
      now = sent_at + 3_600

      headers = [
        {"svix-id", "msg_6"},
        {"svix-timestamp", "#{sent_at}"},
        {"svix-signature", sign(payload, "msg_6", sent_at)}
      ]

      assert {:error, %Error{message: message}} =
               Webhooks.verify(payload, headers, @secret, now: now)

      assert message =~ "tolerance"

      # A wider tolerance admits the same delivery
      assert {:ok, _} =
               Webhooks.verify(payload, headers, @secret, now: now, tolerance_seconds: 7_200)
    end

    test "rejects missing headers and malformed secrets" do
      assert {:error, %Error{message: message}} = Webhooks.verify("{}", [], @secret)
      assert message =~ "missing webhook header"

      now = 1_756_680_000

      headers = [
        {"svix-id", "msg_7"},
        {"svix-timestamp", "#{now}"},
        {"svix-signature", "v1,abc"}
      ]

      assert {:error, %Error{message: secret_message}} =
               Webhooks.verify("{}", headers, "whsec_!!!not-base64!!!", now: now)

      assert secret_message =~ "not base64"
    end
  end
end
