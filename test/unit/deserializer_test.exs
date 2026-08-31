defmodule DeserializerTest do
  @moduledoc """
  Unit tests for the template-owned `Deserializer` runtime:
  struct/list/map/date/datetime conversions, including nil and
  invalid-input branches.
  """

  use ExUnit.Case, async: true

  @deserializer SdkSurface.deserializer_module()

  defmodule Inner do
    defstruct [:name]

    def decode(model), do: model
  end

  describe "json_decode/1 and json_decode/2" do
    test "decodes valid JSON" do
      assert {:ok, %{"a" => 1}} = @deserializer.json_decode(~s({"a":1}))
    end

    test "returns an error for invalid JSON" do
      assert {:error, _reason} = @deserializer.json_decode("{not json")
    end

    test "decodes into a struct, ignoring unknown fields" do
      assert {:ok, %Inner{name: "x"}} =
               @deserializer.json_decode(~s({"name":"x","extra":1}), Inner)
    end

    test "decodes a JSON array into a list of structs" do
      assert {:ok, [%Inner{name: "x"}, %Inner{name: "y"}]} =
               @deserializer.json_decode(~s([{"name":"x"},{"name":"y"}]), Inner)
    end

    test "propagates decode errors with a module" do
      assert {:error, _reason} = @deserializer.json_decode("{not json", Inner)
    end
  end

  describe "deserialize/4" do
    test ":struct converts a nested map and leaves nil alone" do
      model = %{child: %{"name" => "x"}, empty: nil}

      assert %{child: %Inner{name: "x"}} =
               @deserializer.deserialize(model, :child, :struct, Inner)

      assert %{empty: nil} = @deserializer.deserialize(model, :empty, :struct, Inner)
    end

    test ":list converts each element and leaves nil alone" do
      model = %{children: [%{"name" => "x"}], empty: nil}

      assert %{children: [%Inner{name: "x"}]} =
               @deserializer.deserialize(model, :children, :list, Inner)

      assert %{empty: nil} = @deserializer.deserialize(model, :empty, :list, Inner)
    end

    test ":map converts each value and leaves nil alone" do
      model = %{by_id: %{"a" => %{"name" => "x"}}, empty: nil}

      assert %{by_id: %{"a" => %Inner{name: "x"}}} =
               @deserializer.deserialize(model, :by_id, :map, Inner)

      assert %{empty: nil} = @deserializer.deserialize(model, :empty, :map, Inner)
    end

    test ":date parses ISO 8601 dates and keeps invalid or absent values" do
      assert %{on: ~D[2026-07-19]} =
               @deserializer.deserialize(%{on: "2026-07-19"}, :on, :date, nil)

      assert %{on: "not a date"} = @deserializer.deserialize(%{on: "not a date"}, :on, :date, nil)
      assert %{on: 5} = @deserializer.deserialize(%{on: 5}, :on, :date, nil)
    end

    test ":datetime parses ISO 8601 datetimes and keeps invalid or absent values" do
      assert %{at: ~U[2026-07-19 12:00:00Z]} =
               @deserializer.deserialize(%{at: "2026-07-19T12:00:00Z"}, :at, :datetime, nil)

      assert %{at: "nope"} = @deserializer.deserialize(%{at: "nope"}, :at, :datetime, nil)
      assert %{at: 5} = @deserializer.deserialize(%{at: 5}, :at, :datetime, nil)
    end

    test ":struct passes scalar values to the module decode" do
      assert %{child: "raw"} = @deserializer.deserialize(%{child: "raw"}, :child, :struct, Inner)
    end
  end
end
