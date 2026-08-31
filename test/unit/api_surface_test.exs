defmodule ApiSurfaceTest do
  @moduledoc """
  Smoke coverage of every generated API operation.

  Every exported function in the generated `Api.*` modules is called against
  a catch-all mock server. Each operation must build its request, perform
  the HTTP round trip, and return an `{:ok, _}` or `{:error, _}` tuple
  without raising — guarding the generated request pipelines (including
  multipart/file-upload building) across regenerations of the SDK.
  """

  use ExUnit.Case, async: true

  @connection SdkSurface.connection_module()

  test "every operation performs a request and returns an ok or error tuple" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, "{}")
    end)

    # Dummy argument for every required parameter. It is a real file path
    # so operations with file-upload parameters can build their multipart
    # bodies; for path, body, and form parameters it is just a string.
    dummy =
      Path.join(
        System.tmp_dir!(),
        "api_surface_#{System.unique_integer([:positive])}"
      )

    File.write!(dummy, "dummy")
    on_exit(fn -> File.rm(dummy) end)

    conn = @connection.new(base_url: "http://localhost:#{bypass.port}", retry: false)

    failures =
      for module <- SdkSurface.api_modules(), {fun, arity} <- operations(module), reduce: [] do
        acc ->
          args = [conn | List.duplicate(dummy, arity - 1)]

          try do
            case apply(module, fun, args) do
              {:ok, _decoded} -> acc
              {:error, _reason} -> acc
              other -> [{module, fun, {:unexpected_return, other}} | acc]
            end
          rescue
            error -> [{module, fun, error} | acc]
          catch
            kind, reason -> [{module, fun, {kind, reason}} | acc]
          end
      end

    assert failures == []
  end

  test "the generated API surface is present" do
    operation_count =
      SdkSurface.api_modules()
      |> Enum.map(&length(operations(&1)))
      |> Enum.sum()

    assert SdkSurface.api_modules() != []
    assert operation_count > 0
  end

  # Every operation is exported once per default argument; calling the
  # lowest arity exercises the same body with default opts.
  defp operations(module) do
    {:module, ^module} = Code.ensure_loaded(module)

    module.__info__(:functions)
    |> Enum.group_by(fn {name, _arity} -> name end, fn {_name, arity} -> arity end)
    |> Enum.map(fn {name, arities} -> {name, Enum.min(arities)} end)
  end
end
