defmodule ExDaytona.SecurityFacadeTest do
  use TestCase, async: true

  alias ExDaytona.Client
  alias ExDaytona.Error
  alias ExDaytona.Model
  alias ExDaytona.Platform
  alias ExDaytona.Sandbox
  alias ExDaytona.Secrets

  setup do
    bypass = MockServer.setup()

    {:ok, client} =
      Client.new(api_key: "dtn_test", base_url: MockServer.url(bypass), retry: false)

    {:ok, bypass: bypass, client: client}
  end

  describe "Sandbox.create/2 security options" do
    test "sends network policy, secrets, and pause interval", %{bypass: bypass, client: client} do
      MockServer.expect_once(bypass, "POST", "/sandbox", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{
                 "domainAllowList" => "example.com,*.daytona.io",
                 "networkAllowList" => "10.0.0.0/24",
                 "autoPauseInterval" => 30,
                 "secrets" => [%{"DB_PASSWORD" => "db-prod"}],
                 "spot" => true,
                 "gpuType" => "a100"
               } = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "sb-sec", state: "creating"}))
      end)

      assert {:ok, %Sandbox{}} =
               Sandbox.create(client,
                 wait: false,
                 domain_allow_list: "example.com,*.daytona.io",
                 network_allow_list: "10.0.0.0/24",
                 auto_pause_interval: 30,
                 secrets: [%{"DB_PASSWORD" => "db-prod"}],
                 spot: true,
                 gpu_type: "a100"
               )
    end

    test "rejects malformed secret bindings before any request", %{client: client} do
      assert {:error, %Error{message: message}} =
               Sandbox.create(client, wait: false, secrets: [%{"A" => "x", "B" => "y"}])

      assert message =~ "single-entry maps"

      assert {:error, %Error{}} =
               Sandbox.create(client, wait: false, secrets: %{"A" => "x"})

      assert {:error, %Error{}} =
               Sandbox.create(client, wait: false, secrets: [%{"A" => 1}])
    end

    test "still rejects unknown options", %{client: client} do
      assert {:error, %Error{message: message}} =
               Sandbox.create(client, wait: false, domain_allowlist: "typo.com")

      assert message =~ "unknown sandbox option :domain_allowlist"
    end
  end

  describe "Sandbox.update_network_settings/2" do
    test "posts the policy and returns the updated sandbox", %{bypass: bypass, client: client} do
      sandbox = %Sandbox{client: client, info: %Model.Sandbox{id: "sb-1", state: "started"}}

      MockServer.expect_once(bypass, "POST", "/sandbox/sb-1/network-settings", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"networkBlockAll" => true} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!(%{id: "sb-1", state: "started", networkBlockAll: true})
        )
      end)

      assert {:ok, %Sandbox{info: %{networkBlockAll: true}}} =
               Sandbox.update_network_settings(sandbox, network_block_all: true)
    end

    test "rejects unknown settings", %{client: client} do
      sandbox = %Sandbox{client: client, info: %Model.Sandbox{id: "sb-1"}}

      assert {:error, %Error{message: message}} =
               Sandbox.update_network_settings(sandbox, allow: "x")

      assert message =~ "unknown network settings"
    end
  end

  describe "Secrets" do
    test "create/get/list/update/delete round-trip", %{bypass: bypass, client: client} do
      MockServer.expect_once(bypass, "POST", "/secret", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"name" => "db-prod", "value" => "s3cr3t"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, JSON.encode!(%{id: "sec-1", name: "db-prod"}))
      end)

      assert {:ok, %Model.Secret{id: "sec-1"} = created} =
               Secrets.create(client, "db-prod", "s3cr3t", hosts: ["db.example.com"])

      refute inspect(created) =~ "s3cr3t"

      MockServer.expect_get(bypass, "/secret/sec-1", 200, %{id: "sec-1", name: "db-prod"})
      assert {:ok, %Model.Secret{}} = Secrets.get(client, "sec-1")

      MockServer.expect_once(bypass, "GET", "/secret/paginated", fn conn ->
        assert URI.decode_query(conn.query_string)["limit"] == "5"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!(%{items: [%{id: "sec-1", name: "db-prod"}], total: 1, nextCursor: "c2"})
        )
      end)

      assert {:ok, %{items: [%Model.Secret{}], next_cursor: "c2", total: 1}} =
               Secrets.list(client, limit: 5)

      MockServer.expect_once(bypass, "PATCH", "/secret/sec-1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"value" => "rotated"} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "sec-1", name: "db-prod"}))
      end)

      assert {:ok, %Model.Secret{}} = Secrets.update(client, "sec-1", value: "rotated")

      MockServer.expect_delete(bypass, "/secret/sec-1", 204)
      assert :ok = Secrets.delete(client, "sec-1")
    end

    test "sandbox bindings: replace and resolve with redacted values", %{
      bypass: bypass,
      client: client
    } do
      sandbox = %Sandbox{client: client, info: %Model.Sandbox{id: "sb-1"}}

      MockServer.expect_once(bypass, "PUT", "/sandbox/sb-1/secrets", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"secrets" => [%{"DB_PASSWORD" => "db-prod"}]} = JSON.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, JSON.encode!(%{id: "sb-1", state: "started"}))
      end)

      assert {:ok, %Sandbox{}} =
               Secrets.set_sandbox_bindings(sandbox, [%{"DB_PASSWORD" => "db-prod"}])

      MockServer.expect_get(bypass, "/sandbox/sb-1/secrets", 200, [
        %{env: "DB_PASSWORD", value: "PLAINTEXTCANARY", placeholder: "***"}
      ])

      assert {:ok, [resolved]} = Secrets.resolve(sandbox)
      assert resolved.value == "PLAINTEXTCANARY"
      refute inspect(resolved) =~ "PLAINTEXTCANARY"
    end
  end

  describe "Platform" do
    test "regions, sandbox classes, snapshots, and usage overview", %{
      bypass: bypass,
      client: client
    } do
      MockServer.expect_get(bypass, "/regions", 200, [%{id: "us", name: "United States"}])
      assert {:ok, [%Model.Region{id: "us"}]} = Platform.regions(client)

      MockServer.expect_get(bypass, "/organizations/org-1/available-sandbox-classes", 200, [
        %{sandboxClass: "small", gpuAvailable: false}
      ])

      assert {:ok, [%Model.AvailableSandboxClass{sandboxClass: "small"}]} =
               Platform.sandbox_classes(client, "org-1")

      MockServer.expect_once(bypass, "GET", "/snapshots", fn conn ->
        assert URI.decode_query(conn.query_string)["limit"] == "10"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!(%{items: [%{id: "snap-1"}], page: 1, total: 1, totalPages: 1})
        )
      end)

      assert {:ok, %{items: [%Model.SnapshotDto{id: "snap-1"}], total: 1}} =
               Platform.snapshots(client, limit: 10)

      MockServer.expect_get(bypass, "/organizations/org-1/usage", 200, %{})
      assert {:ok, %Model.OrganizationUsageOverview{}} = Platform.usage_overview(client, "org-1")
    end
  end
end
