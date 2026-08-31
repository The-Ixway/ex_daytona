defmodule ModelSurfaceTest do
  @moduledoc """
  Smoke coverage of every generated model module.

  Each generated `Model.*` module must build its struct (when it defines
  one) and run its `decode/1` pipeline without raising. This guards the
  generated deserialization chains across regenerations of the SDK.
  """

  use ExUnit.Case, async: true

  test "every model module builds a struct and decodes" do
    failures =
      Enum.reduce(SdkSurface.model_modules(), [], fn module, acc ->
        {:module, ^module} = Code.ensure_loaded(module)

        input =
          if function_exported?(module, :__struct__, 1) do
            struct(module)
          else
            %{}
          end

        try do
          module.decode(input)
          acc
        rescue
          error -> [{module, error} | acc]
        end
      end)

    assert failures == []
  end

  test "the generated model surface is present" do
    assert SdkSurface.model_modules() != []
  end
end
