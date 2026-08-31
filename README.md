# ex_daytona

[![Hex.pm](https://img.shields.io/hexpm/v/ex_daytona.svg)](https://hex.pm/packages/ex_daytona)
[![Documentation](https://img.shields.io/badge/hexdocs-ex__daytona-blue.svg)](https://hexdocs.pm/ex_daytona)
[![CI](https://github.com/The-Ixway/ex_daytona/actions/workflows/test.yml/badge.svg)](https://github.com/The-Ixway/ex_daytona/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-green.svg)](LICENSE)

Unofficial Elixir SDK for the [Daytona](https://www.daytona.io) AI sandbox
platform — covering the main platform API, the per-sandbox toolbox API, and
the analytics API in one package. Generated from Daytona's published OpenAPI
specs (merged by `scripts/fetch-spec.sh`).

> **Note:** This is a community project, not maintained by Daytona Platforms Inc.

## Installation

Add `ex_daytona` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_daytona, "~> 0.1.0"}
  ]
end
```

## Configuration

```elixir
# config/runtime.exs
config :ex_daytona,
  base_url: System.get_env("API_BASE_URL", "https://app.daytona.io/api")
```

## Usage

Get an API key at [app.daytona.io/dashboard/keys](https://app.daytona.io/dashboard/keys).

```elixir
# Create a connection to the main platform API
conn = ExDaytona.Connection.new(bearer_token: System.fetch_env!("DAYTONA_API_KEY"))

# List your sandboxes — responses decode into typed model structs
{:ok, sandboxes} = ExDaytona.Api.Sandbox.list_sandboxes(conn)

# Create a sandbox
{:ok, %ExDaytona.Model.Sandbox{} = sandbox} =
  ExDaytona.Api.Sandbox.create_sandbox(conn, %ExDaytona.Model.CreateSandbox{})
```

## Base URLs

Daytona's API surface spans three services with different base URLs, all
covered by this one SDK — pick the base URL per `Connection`:

| API | Modules (examples) | Base URL |
| --- | --- | --- |
| Main platform | `ExDaytona.Api.Sandbox`, `Organizations`, `Snapshots`, `Volumes`, … | `https://app.daytona.io/api` (default) |
| Toolbox (inside a sandbox) | `ExDaytona.Api.Process`, `FileSystem`, `Git`, `Lsp`, `ComputerUse`, … | `{toolboxProxyUrl}/{sandboxId}` — from the sandbox's `toolboxProxyUrl` field |
| Analytics | `ExDaytona.Api.Usage`, `Telemetry` | `https://analytics.app.daytona.io` |

```elixir
# Toolbox: execute a command inside a sandbox you created above
token = System.fetch_env!("DAYTONA_API_KEY")

toolbox_conn =
  ExDaytona.Connection.new(
    base_url: "#{sandbox.toolboxProxyUrl}/#{sandbox.id}",
    bearer_token: token
  )

{:ok, result} =
  ExDaytona.Api.Process.execute_command(
    toolbox_conn,
    %ExDaytona.Model.ExecuteRequest{command: "echo hello"}
  )

# Analytics
analytics_conn =
  ExDaytona.Connection.new(
    base_url: "https://analytics.app.daytona.io",
    bearer_token: token
  )
```

## Error handling

Operations return one of three shapes — note that `{:ok, _}` alone is **not**
a safe success match:

1. **Success statuses** decode into the mapped model struct.
2. **Error statuses declared in the OpenAPI spec** *also* return `:ok`,
   wrapping the spec's error model (an openapi-generator convention) — e.g. a
   400 comes back as `{:ok, %ExDaytona.Model.SomeErrorResponse{}}`. Match on
   the struct, not just the tuple tag.
3. **Statuses the spec does not declare** (gateway 401/403s, proxy 502s, rate
   limits) return `{:error, %Tesla.Env{status: status, body: body}}`, with
   the body decoded to a map when the response is JSON.

Transport failures (connection refused, timeouts, DNS) surface as
`{:error, reason}` where `reason` comes from the configured Tesla adapter —
e.g. `%Finch.TransportError{}` with the default Finch adapter.

## Live smoke testing

The unit suite mocks the API from the spec, so it cannot catch places where
the spec and the real server disagree. A live smoke-test scaffold ships in
`test/integration/live_test.exs` (tagged `:live`, excluded by default):

```bash
SDK_LIVE_BASE_URL=https://app.daytona.io/api SDK_LIVE_TOKEN=... mix test.live
```

## Development

```bash
./scripts/fetch-spec.sh   # refresh openapi-spec.yaml from Daytona's three upstream specs
./scripts/regenerate.sh   # regenerate from openapi-spec.yaml
mix check                 # full quality gate (mirrors CI)
mix dialyzer              # type check
```

## Documentation

- [API Documentation](https://hexdocs.pm/ex_daytona)
- [Changelog](CHANGELOG.md)

## License

See [LICENSE](LICENSE) for details.

---

**Generated with ❤️ using the [Elixir SDK Generator](https://github.com/houllette/elixir-sdk-generator) template**
