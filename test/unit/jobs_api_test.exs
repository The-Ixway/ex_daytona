defmodule ExDaytona.Api.JobsTest do
  use TestCase, async: true

  alias ExDaytona.Api.Jobs
  alias ExDaytona.Connection
  alias ExDaytona.Model

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  describe "list_jobs/2" do
    test "decodes the paginated wrapper and its items", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/jobs", 200, %{
        items: [%{id: "job-1", status: "completed", resourceType: "sandbox"}],
        page: 1,
        total: 1,
        totalPages: 1
      })

      assert {:ok, %Model.PaginatedJobs{items: [item], page: 1}} = Jobs.list_jobs(conn)
      assert %Model.Job{id: "job-1", status: "completed"} = item
    end
  end

  describe "get_job/3" do
    test "decodes a single Job", %{bypass: bypass, conn: conn} do
      MockServer.expect_get(bypass, "/jobs/job-1", 200, %{id: "job-1", status: "running"})

      assert {:ok, %Model.Job{id: "job-1", status: "running"}} = Jobs.get_job(conn, "job-1")
    end
  end
end
