defmodule ExDaytona.ClientTest do
  use TestCase, async: false

  alias ExDaytona.Client
  alias ExDaytona.Error

  # async: false — some tests mutate the DAYTONA_API_KEY environment
  # variable, which is global state.

  setup do
    original = System.get_env("DAYTONA_API_KEY")

    on_exit(fn ->
      if original do
        System.put_env("DAYTONA_API_KEY", original)
      else
        System.delete_env("DAYTONA_API_KEY")
      end
    end)

    :ok
  end

  describe "new/1" do
    test "builds a client from an explicit api_key" do
      assert {:ok, %Client{api_key: "dtn_test", conn: %Tesla.Client{}}} =
               Client.new(api_key: "dtn_test")
    end

    test "falls back to the DAYTONA_API_KEY environment variable" do
      System.put_env("DAYTONA_API_KEY", "dtn_from_env")

      assert {:ok, %Client{api_key: "dtn_from_env"}} = Client.new()
    end

    test "returns a clear error when no key is available" do
      System.delete_env("DAYTONA_API_KEY")

      assert {:error, %Error{message: message}} = Client.new()
      assert message =~ "DAYTONA_API_KEY"
    end

    test "authenticates requests with the key and honors base_url", %{} do
      bypass = MockServer.setup()

      Bypass.expect_once(bypass, "GET", "/sandbox", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer dtn_test"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{items: []}))
      end)

      {:ok, client} = Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass))

      assert {:ok, %{items: []}} = ExDaytona.Sandbox.list(client)
    end
  end

  describe "new!/1" do
    test "returns the client directly on success" do
      assert %Client{api_key: "dtn_test"} = Client.new!(api_key: "dtn_test")
    end

    test "raises when no key is available" do
      System.delete_env("DAYTONA_API_KEY")

      assert_raise ArgumentError, ~r/DAYTONA_API_KEY/, fn -> Client.new!() end
    end
  end

  describe "conn/1" do
    test "exposes the underlying Tesla client for generated API calls" do
      {:ok, client} = Client.new(api_key: "dtn_test")

      assert %Tesla.Client{} = Client.conn(client)
    end
  end
end
