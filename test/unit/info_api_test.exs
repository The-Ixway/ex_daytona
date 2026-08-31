defmodule ExDaytona.Api.InfoTest do
  use TestCase, async: true

  alias ExDaytona.Api.Info
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_version/2" do
    test "an untyped-object mapping decodes to a plain map", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/version", 200, %{version: "v0.0.0-dev"})

      # {200, %{}} in the mapping — no model, plain JSON decode.
      assert {:ok, %{"version" => "v0.0.0-dev"}} = Info.get_version(conn)
    end
  end

  describe "get_work_dir/2" do
    test "decodes the WorkDirResponse", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/work-dir", 200, %{dir: "/workspace"})

      assert {:ok, %Model.WorkDirResponse{dir: "/workspace"}} = Info.get_work_dir(conn)
    end
  end

  describe "get_user_home_dir/2" do
    test "decodes the UserHomeDirResponse", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/user-home-dir", 200, %{dir: "/home/daytona"})

      assert {:ok, %Model.UserHomeDirResponse{dir: "/home/daytona"}} =
               Info.get_user_home_dir(conn)
    end
  end
end
