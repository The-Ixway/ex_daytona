defmodule ExDaytona.Api.PreviewTest do
  use TestCase, async: true

  alias ExDaytona.Api.Preview
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "is_preview_warning_enabled/3" do
    test "decodes the PreviewWarning flag", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/preview/sb-1/preview-warning", 200, %{enabled: true})

      assert {:ok, %Model.PreviewWarning{enabled: true}} =
               Preview.is_preview_warning_enabled(conn, "sb-1")
    end
  end

  describe "is_sandbox_public/3" do
    test "a 200 mapped as passthrough returns the raw env", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/preview/sb-1/public", 200, %{})

      assert {:ok, %Tesla.Env{status: 200}} = Preview.is_sandbox_public(conn, "sb-1")
    end
  end
end
