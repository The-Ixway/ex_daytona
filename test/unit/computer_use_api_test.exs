defmodule ExDaytona.Api.ComputerUseTest do
  use TestCase, async: true

  alias ExDaytona.Api.ComputerUse
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "take_screenshot/2" do
    test "decodes the ScreenshotResponse", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/computeruse/screenshot", 200, %{
        screenshot: "iVBORw0KGgo=",
        sizeBytes: 12
      })

      assert {:ok, %Model.ScreenshotResponse{screenshot: "iVBORw0KGgo=", sizeBytes: 12}} =
               ComputerUse.take_screenshot(conn)
    end
  end

  describe "get_mouse_position/2" do
    test "decodes the MousePositionResponse", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/computeruse/mouse/position", 200, %{x: 10, y: 20})

      assert {:ok, %Model.MousePositionResponse{x: 10, y: 20}} =
               ComputerUse.get_mouse_position(conn)
    end
  end

  describe "press_key/3" do
    test "posts the key and decodes the untyped-object response to a plain map", %{
      bypass: bypass,
      conn: conn
    } do
      MockServer.expect_once(bypass, "POST", "/computeruse/keyboard/key", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"key" => "Return"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{success: true}))
      end)

      # {200, %{}} in the mapping — no model, plain JSON decode.
      assert {:ok, %{"success" => true}} =
               ComputerUse.press_key(conn, %Model.KeyboardPressRequest{key: "Return"})
    end
  end
end
