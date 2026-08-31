defmodule TestSupportTest do
  @moduledoc """
  Unit tests for the persistent test support modules (`TestCase`, `Fixtures`).

  These run before and after SDK generation. After generating your SDK, the
  post-generation script also creates a starter test file per API module in
  this directory — flesh those out with real operation tests.
  """

  use TestCase

  describe "mock_client/1 with Mox stubs" do
    test "expect_success_response stubs a successful call" do
      expect_success_response(200, %{"ok" => true})

      client = mock_client()

      assert {:ok, env} = Tesla.get(client, "/anything")
      assert env.status == 200
      assert env.body == %{"ok" => true}
    end

    test "expect_error_response stubs an error status" do
      expect_error_response(404, %{"error" => "not found"})

      client = mock_client()

      assert {:ok, env} = Tesla.get(client, "/missing")
      assert env.status == 404
      assert env.body == %{"error" => "not found"}
    end

    test "expect_network_error stubs a transport failure" do
      expect_network_error(:timeout)

      client = mock_client()

      assert {:error, :timeout} = Tesla.get(client, "/slow")
    end
  end

  describe "fixtures" do
    test "user fixture has expected defaults" do
      user = Fixtures.fixture(:user)

      assert user.id == 1
      assert is_binary(user.email)
    end

    test "error fixtures carry status codes" do
      assert Fixtures.fixture(:validation_error).code == 422
      assert Fixtures.fixture(:not_found_error).code == 404
      assert Fixtures.fixture(:unauthorized_error).code == 401
    end
  end
end
