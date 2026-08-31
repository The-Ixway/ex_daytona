defmodule ExDaytona.Api.ObjectStorageTest do
  use TestCase, async: true

  alias ExDaytona.Api.ObjectStorage
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "get_push_access/2" do
    test "decodes the StorageAccessDto credentials", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/object-storage/push-access", 200, %{
        accessKey: "AKIA...",
        secret: "shh",
        sessionToken: "tok",
        bucket: "daytona-uploads",
        storageUrl: "https://s3.amazonaws.com",
        organizationId: "org-1"
      })

      assert {:ok, %Model.StorageAccessDto{accessKey: "AKIA...", bucket: "daytona-uploads"}} =
               ObjectStorage.get_push_access(conn)
    end
  end
end
