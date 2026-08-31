defmodule ExDaytona.ErrorTest do
  use TestCase, async: true

  alias ExDaytona.Error
  alias ExDaytona.Model.ErrorResponse

  describe "normalize/1" do
    test "passes successful values through" do
      assert {:ok, %{"a" => 1}} = Error.normalize({:ok, %{"a" => 1}})
      assert {:ok, [1, 2]} = Error.normalize({:ok, [1, 2]})
    end

    test "passes 2xx Tesla.Env passthroughs through" do
      assert {:ok, %Tesla.Env{status: 204}} = Error.normalize({:ok, %Tesla.Env{status: 204}})
    end

    test "converts spec-declared error models (the {:ok, error_struct} convention)" do
      result = {:ok, %ErrorResponse{statusCode: 400, message: "bad input", code: "BAD_REQUEST"}}

      assert {:error, %Error{status: 400, message: "bad input", code: "BAD_REQUEST"}} =
               Error.normalize(result)
    end

    test "converts declared statuses passed through as 4xx/5xx envs" do
      env = %Tesla.Env{status: 404, body: %{"message" => "not found"}}

      assert {:error, %Error{status: 404, message: "not found"}} = Error.normalize({:ok, env})
    end

    test "converts undeclared-status error envs" do
      env = %Tesla.Env{
        status: 401,
        body: %{"error" => "Unauthorized", "message" => "Invalid credentials"}
      }

      assert {:error, %Error{status: 401, message: "Invalid credentials", code: "Unauthorized"}} =
               Error.normalize({:error, env})
    end

    test "converts transport failures" do
      assert {:error, %Error{status: nil, message: message}} =
               Error.normalize({:error, :econnrefused})

      assert message =~ "econnrefused"
    end

    test "uses Exception.message/1 for exception reasons" do
      assert {:error, %Error{message: "kaboom"}} =
               Error.normalize({:error, %RuntimeError{message: "kaboom"}})
    end

    test "passes an already-normalized Error through from/1" do
      error = %Error{status: 418, message: "teapot"}

      assert Error.from(error) == error
    end

    test "keeps a non-JSON error body as the message" do
      env = %Tesla.Env{status: 502, body: "Bad Gateway"}

      assert {:error, %Error{status: 502, message: "Bad Gateway"}} = Error.normalize({:ok, env})
    end

    test "falls back to HTTP status when the body is empty" do
      assert {:error, %Error{message: "HTTP 500"}} =
               Error.normalize({:ok, %Tesla.Env{status: 500, body: ""}})
    end
  end
end
