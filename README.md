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

Get an API key at [app.daytona.io/dashboard/keys](https://app.daytona.io/dashboard/keys)
and set `DAYTONA_API_KEY` (or pass `api_key:` explicitly).

### High-level facade (recommended)

```elixir
{:ok, client} = ExDaytona.Client.new()

# Create a sandbox (waits until it's running) and use it
{:ok, sandbox} = ExDaytona.Sandbox.create(client, ttl_minutes: 30)

{:ok, %{exit_code: 0, output: out}} =
  ExDaytona.Sandbox.exec(sandbox, "echo hello", cwd: "/tmp", env: %{"FOO" => "bar"})

:ok = ExDaytona.Sandbox.write_file(sandbox, "/tmp/hello.txt", "hi")
{:ok, "hi"} = ExDaytona.Sandbox.read_file(sandbox, "/tmp/hello.txt")
{:ok, files} = ExDaytona.Sandbox.list_files(sandbox, "/tmp")

{:ok, sandbox} = ExDaytona.Sandbox.stop(sandbox)
{:ok, sandbox} = ExDaytona.Sandbox.start(sandbox)
:ok = ExDaytona.Sandbox.delete(sandbox)
```

Facade calls return `{:ok, value}` or `{:error, %ExDaytona.Error{status, message, code, details}}` —
all of the generated client's response conventions are normalized away.

### Sessions — long-running commands with streamed logs

A session is a persistent shell inside the sandbox: commands share state
and can run asynchronously with real-time log streaming.

```elixir
{:ok, session} = ExDaytona.Session.create(sandbox)

# Commands share environment and working directory
{:ok, %{exit_code: 0}} = ExDaytona.Session.run(session, "export TARGET=prod")
{:ok, %{output: "prod\n"}} = ExDaytona.Session.run(session, "echo $TARGET")

# Long-running: start it, stream the logs live, reap the exit code
{:ok, cmd_id} = ExDaytona.Session.run_async(session, "mix test 2>&1")
:ok = ExDaytona.Session.stream_logs(session, cmd_id, &IO.write/1)
{:ok, %{exit_code: 0}} = ExDaytona.Session.await(session, cmd_id)

{:ok, logs} = ExDaytona.Session.logs(session, cmd_id)   # everything so far
:ok = ExDaytona.Session.delete(session)
```

`ExDaytona.Sandbox.stream_build_logs/3` streams a building sandbox's build
logs the same way.

### Git

```elixir
:ok = ExDaytona.Git.clone(sandbox, "https://github.com/org/repo.git", "/tmp/repo")

{:ok, status} = ExDaytona.Git.status(sandbox, "/tmp/repo")
{:ok, %{branches: _, current: "main"}} = ExDaytona.Git.branches(sandbox, "/tmp/repo")
{:ok, commits} = ExDaytona.Git.history(sandbox, "/tmp/repo")

:ok = ExDaytona.Git.create_branch(sandbox, "/tmp/repo", "feature/x")
:ok = ExDaytona.Git.checkout(sandbox, "/tmp/repo", "feature/x")
:ok = ExDaytona.Git.add(sandbox, "/tmp/repo", ["README.md"])

{:ok, %{hash: _}} =
  ExDaytona.Git.commit(sandbox, "/tmp/repo", "docs: update",
    author: "Dev", email: "dev@example.com")

# push/pull take :username/:password (use a token as the password)
:ok = ExDaytona.Git.push(sandbox, "/tmp/repo", username: "bot", password: token)
```

### Low-level generated API (full surface)

Every endpoint of all three APIs is available through the generated
modules — use them for anything the facade doesn't cover:

```elixir
conn = ExDaytona.Client.conn(client)   # or ExDaytona.Connection.new(bearer_token: ...)

{:ok, sandboxes} = ExDaytona.Api.Sandbox.list_sandboxes(conn)
{:ok, snapshots} = ExDaytona.Api.Snapshots.get_all_snapshots(conn)

# Toolbox APIs the facade doesn't wrap (Git, LSP, computer-use, ...)
{:ok, tconn} = ExDaytona.Sandbox.toolbox_conn(sandbox)
{:ok, status} = ExDaytona.Api.Git.get_status(tconn, "/workspace/repo")
```

## Base URLs

Daytona's API surface spans three services with different base URLs, all
covered by this one SDK — pick the base URL per `Connection`:

| API | Modules (examples) | Base URL |
| --- | --- | --- |
| Main platform | `ExDaytona.Api.Sandbox`, `Organizations`, `Snapshots`, `Volumes`, … | `https://app.daytona.io/api` (default) |
| Toolbox (inside a sandbox) | `ExDaytona.Api.Process`, `FileSystem`, `Git`, `Lsp`, `ComputerUse`, … | `{toolboxProxyUrl}/{sandboxId}` — from the sandbox's `toolboxProxyUrl` field |
| Analytics | `ExDaytona.Api.Usage`, `Telemetry` | `https://analytics.app.daytona.io` |

The `ExDaytona.Toolbox` and `ExDaytona.Analytics` helpers build correctly
targeted connections for you:

```elixir
# Toolbox: execute a command inside a sandbox you created above
token = System.fetch_env!("DAYTONA_API_KEY")

toolbox_conn = ExDaytona.Toolbox.connection(sandbox, bearer_token: token)

{:ok, result} =
  ExDaytona.Api.Process.execute_command(
    toolbox_conn,
    %ExDaytona.Model.ExecuteRequest{command: "echo hello"}
  )

# Analytics (base URL configurable via `config :ex_daytona, :analytics_base_url`)
analytics_conn = ExDaytona.Analytics.connection(bearer_token: token)

{:ok, usage} =
  ExDaytona.Api.Usage.get_organization_usage_aggregated(
    analytics_conn,
    org_id,
    "2026-01-01T00:00:00Z",
    "2026-02-01T00:00:00Z"
  )
```

## Error handling

**Facade functions** (`ExDaytona.Client` / `ExDaytona.Sandbox`) always return
`{:ok, value}` or `{:error, %ExDaytona.Error{}}` — use them and skip the
rest of this section.

**Low-level generated operations** return one of three shapes — note that
`{:ok, _}` alone is **not** a safe success match:

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
