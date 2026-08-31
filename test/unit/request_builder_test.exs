defmodule RequestBuilderTest do
  @moduledoc """
  Unit tests for the template-owned `RequestBuilder` runtime: every
  `add_param/4` location (including the form/file multipart composition),
  `add_optional_params/3` routing, `ensure_body/1`, and all
  `evaluate_response/2` mapping paths.
  """

  use ExUnit.Case, async: true

  @rb SdkSurface.request_builder_module()
  @model SdkSurface.sample_model_module()

  describe "method/2 and url/2" do
    test "set the request method and url" do
      assert %{method: :get} = @rb.method(%{}, :get)
      assert %{url: "/things"} = @rb.url(%{}, "/things")
    end
  end

  describe "add_param/4" do
    test "puts a raw body" do
      assert %{body: %{a: 1}} = @rb.add_param(%{}, :body, :body, %{a: 1})
    end

    test "adds a named body part as a JSON multipart field" do
      request = @rb.add_param(%{}, :body, :metadata, %{a: 1})

      assert %Tesla.Multipart{parts: [part]} = request.body
      assert part.body == ~s({"a":1})
    end

    test "stores headers, replacing duplicates" do
      request =
        %{}
        |> @rb.add_param(:headers, :"x-token", "one")
        |> @rb.add_param(:headers, :"x-token", "two")

      assert request.headers == [{"x-token", "two"}]
    end

    test "adds a file as a multipart part" do
      path = tmp_file!()

      assert %{body: %Tesla.Multipart{parts: [_part]}} = @rb.add_param(%{}, :file, :file, path)
    end

    test "merges form fields into the body map" do
      request =
        %{}
        |> @rb.add_param(:form, :purpose, "batch")
        |> @rb.add_param(:form, :name, "test")

      assert request.body == %{purpose: "batch", name: "test"}
    end

    test "form and file parameters compose into one multipart in either order" do
      path = tmp_file!()

      file_then_form =
        %{}
        |> @rb.add_param(:file, :file, path)
        |> @rb.add_param(:form, :purpose, "batch")

      form_then_file =
        %{}
        |> @rb.add_param(:form, :purpose, "batch")
        |> @rb.add_param(:file, :file, path)

      for request <- [file_then_form, form_then_file] do
        assert %Tesla.Multipart{parts: parts} = request.body
        assert Enum.count(parts) == 2
      end
    end

    test "accumulates query parameters" do
      request =
        %{}
        |> @rb.add_param(:query, :page, 1)
        |> @rb.add_param(:query, :limit, 20)

      assert request.query == [page: 1, limit: 20]
    end
  end

  describe "add_optional_params/3" do
    test "routes known keys to their location and skips unknown keys" do
      definitions = %{page: :query, token: :headers}

      request = @rb.add_optional_params(%{}, definitions, page: 2, token: "t", unknown: "x")

      assert request.query == [page: 2]
      assert request.headers == [{"token", "t"}]
      refute Map.has_key?(request, :unknown)
    end
  end

  describe "ensure_body/1" do
    test "replaces a nil body and adds a missing body" do
      assert %{body: ""} = @rb.ensure_body(%{body: nil})
      assert %{body: ""} = @rb.ensure_body(%{})
      assert %{body: "keep"} = @rb.ensure_body(%{body: "keep"})
    end
  end

  describe "evaluate_response/2" do
    test "decodes a matched status into the mapped struct" do
      env = %Tesla.Env{status: 200, body: ~s({"a":1})}

      assert {:ok, decoded} = @rb.evaluate_response({:ok, env}, [{200, @model}])
      assert decoded.__struct__ == @model
    end

    test "decodes a matched status into a plain map with an empty-map mapping" do
      env = %Tesla.Env{status: 200, body: ~s({"a":1})}

      assert {:ok, %{"a" => 1}} = @rb.evaluate_response({:ok, env}, [{200, %{}}])
    end

    test "returns the env unchanged when mapped to false" do
      env = %Tesla.Env{status: 200, body: "raw bytes"}

      assert {:ok, ^env} = @rb.evaluate_response({:ok, env}, [{200, false}])
    end

    test "falls back to the default mapping" do
      env = %Tesla.Env{status: 418, body: ~s({"a":1})}

      assert {:ok, %{"a" => 1}} = @rb.evaluate_response({:ok, env}, [{:default, %{}}, {200, false}])
    end

    test "returns an error tuple when no mapping matches" do
      env = %Tesla.Env{status: 404, body: ""}

      assert {:error, ^env} = @rb.evaluate_response({:ok, env}, [{200, %{}}])
    end

    test "decodes the JSON body of an unmapped error status" do
      env = %Tesla.Env{
        status: 401,
        body: ~s({"error":"unauthorized"}),
        headers: [{"content-type", "application/json; charset=utf-8"}]
      }

      assert {:error, %Tesla.Env{status: 401, body: %{"error" => "unauthorized"}}} =
               @rb.evaluate_response({:ok, env}, [{200, %{}}])
    end

    test "leaves non-JSON unmapped error bodies untouched" do
      env = %Tesla.Env{
        status: 502,
        body: "<html>Bad Gateway</html>",
        headers: [{"content-type", "text/html"}]
      }

      assert {:error, ^env} = @rb.evaluate_response({:ok, env}, [{200, %{}}])
    end

    test "leaves malformed JSON unmapped error bodies untouched" do
      env = %Tesla.Env{
        status: 500,
        body: "not-json",
        headers: [{"content-type", "application/json"}]
      }

      assert {:error, ^env} = @rb.evaluate_response({:ok, env}, [{200, %{}}])
    end

    test "passes through transport errors" do
      assert {:error, :nxdomain} = @rb.evaluate_response({:error, :nxdomain}, [{200, %{}}])
    end
  end

  defp tmp_file! do
    path = Path.join(System.tmp_dir!(), "request_builder_#{System.unique_integer([:positive])}")
    File.write!(path, "contents")
    on_exit(fn -> File.rm(path) end)
    path
  end
end
