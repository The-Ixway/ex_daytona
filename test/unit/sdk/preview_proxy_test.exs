defmodule ExDaytona.PreviewProxyTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.PreviewProxy

  setup do
    bypass = MockServer.setup()

    {:ok, client} =
      Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass), retry: false)

    {:ok, bypass: bypass, client: client}
  end

  describe "public?/2 and valid_token?/3" do
    test "parse boolean bodies", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/preview/sb-1/public", 200, true)
      assert {:ok, true} = PreviewProxy.public?(client, "sb-1")

      MockServer.expect_get(bypass, "/preview/sb-1/public", 200, false)
      assert {:ok, false} = PreviewProxy.public?(client, "sb-1")

      MockServer.expect_get(bypass, "/preview/sb-1/validate/tok-1", 200, true)
      assert {:ok, true} = PreviewProxy.valid_token?(client, "sb-1", "tok-1")
    end
  end

  describe "access?/2" do
    test "treats the declared 404 mapping as no access", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/preview/sb-gone/access", 404, %{})

      assert {:ok, false} = PreviewProxy.access?(client, "sb-gone")

      MockServer.expect_get(bypass, "/preview/sb-1/access", 200, true)
      assert {:ok, true} = PreviewProxy.access?(client, "sb-1")
    end
  end

  describe "resolve_signed_token/3 and signing_key/2" do
    test "extract from bare-string and object bodies", %{bypass: bypass, client: client} do
      MockServer.expect_once(bypass, "GET", "/preview/signed-tok/3000/sandbox-id", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "sb-42")
      end)

      assert {:ok, "sb-42"} = PreviewProxy.resolve_signed_token(client, "signed-tok", 3000)

      MockServer.expect_get(bypass, "/preview/sb-1/signing-key", 200, %{signingKey: "key-abc"})
      assert {:ok, "key-abc"} = PreviewProxy.signing_key(client, "sb-1")
    end
  end

  describe "preview_warning?/2" do
    test "decodes the flag", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/preview/sb-1/preview-warning", 200, %{enabled: false})

      assert {:ok, false} = PreviewProxy.preview_warning?(client, "sb-1")
    end
  end

  describe "errors" do
    test "undeclared statuses normalize", %{bypass: bypass, client: client} do
      MockServer.expect_get(bypass, "/preview/sb-1/public", 500, %{message: "boom"})

      assert {:error, %Error{status: 500}} = PreviewProxy.public?(client, "sb-1")
    end
  end
end
