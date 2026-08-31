# ex_daytona

[![Hex.pm](https://img.shields.io/hexpm/v/ex_daytona.svg)](https://hex.pm/packages/ex_daytona)
[![Documentation](https://img.shields.io/badge/hexdocs-ex__daytona-blue.svg)](https://hexdocs.pm/ex_daytona)
[![CI](https://github.com/The-Ixway/ex_daytona/actions/workflows/test.yml/badge.svg)](https://github.com/The-Ixway/ex_daytona/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-green.svg)](https://github.com/The-Ixway/ex_daytona/blob/main/LICENSE)

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

### File system

`ExDaytona.FS` is the full file-system surface (the `Sandbox`
read/write/list helpers delegate to it):

```elixir
:ok = ExDaytona.FS.mkdir(sandbox, "/workspace/data", mode: "755")
:ok = ExDaytona.FS.write_files(sandbox, [{"/workspace/a.txt", "one"}, {"/workspace/b.txt", "two"}])

{:ok, %ExDaytona.Model.FileInfo{size: _}} = ExDaytona.FS.stat(sandbox, "/workspace/a.txt")
{:ok, paths} = ExDaytona.FS.search(sandbox, "/workspace", "*.txt")   # glob on names
{:ok, matches} = ExDaytona.FS.grep(sandbox, "/workspace", "TODO")    # search contents
{:ok, _report} = ExDaytona.FS.replace(sandbox, paths, "old", "new")  # per-file results

:ok = ExDaytona.FS.chmod(sandbox, "/workspace/a.txt", mode: "600")
:ok = ExDaytona.FS.move(sandbox, "/workspace/a.txt", "/workspace/archive/a.txt")
:ok = ExDaytona.FS.upload(sandbox, "local.bin", "/workspace/remote.bin")
:ok = ExDaytona.FS.download(sandbox, "/workspace/remote.bin", "copy.bin")
:ok = ExDaytona.FS.delete(sandbox, "/workspace/data", recursive: true)
```

### Code execution

Stateless snippets (fresh interpreter per run; Python/JavaScript/TypeScript):

```elixir
{:ok, %{exit_code: 0, result: "hello\n"}} =
  ExDaytona.Sandbox.run_code(sandbox, "print(sys.argv[1])",
    language: "python", argv: ["hello"], env: %{"FOO" => "BAR"}, timeout: 30)
```

Stateful Python (variables persist between runs; streams over a websocket):

```elixir
{:ok, _} = ExDaytona.CodeInterpreter.run(sandbox, "counter = 41")
{:ok, %{stdout: "42\n"}} = ExDaytona.CodeInterpreter.run(sandbox, "counter += 1\nprint(counter)")

# Stream output live, isolate state into contexts, and surface exceptions
{:ok, ctx} = ExDaytona.CodeInterpreter.create_context(sandbox, cwd: "/workspace")

{:ok, %{error: %{name: "ZeroDivisionError"}}} =
  ExDaytona.CodeInterpreter.run(sandbox, "1/0",
    context: ctx, on_stdout: &IO.write/1, on_stderr: &IO.write/1)
```

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

# Interactive commands: answer prompts over stdin
{:ok, cmd_id} = ExDaytona.Session.run_async(session, "read a; echo got:$a", suppress_input_echo: true)
:ok = ExDaytona.Session.send_input(session, cmd_id, "yes\n")

:ok = ExDaytona.Session.delete(session)
```

`ExDaytona.Session.entrypoint/1` and `entrypoint_logs/1` expose the
session a configured entrypoint runs in.

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

### PTY — interactive terminals over websockets

```elixir
{:ok, pty} = ExDaytona.Pty.create(sandbox, cols: 120, rows: 30)
{:ok, ws} = ExDaytona.Pty.connect(pty)   # terminal output arrives as messages

:ok = ExDaytona.Pty.send_input(ws, "htop\n")

receive do
  {:ex_daytona_ws, ^ws, {:binary, output}} -> IO.write(output)
end

:ok = ExDaytona.Pty.resize(pty, 200, 50)
:ok = ExDaytona.Pty.disconnect(ws)
:ok = ExDaytona.Pty.delete(pty)
```

### SSH access

```elixir
{:ok, %{ssh_command: cmd, token: token}} =
  ExDaytona.Sandbox.ssh_access(sandbox, expires_in_minutes: 60)
# cmd => "ssh <token>@ssh.app.daytona.io"

:ok = ExDaytona.Sandbox.revoke_ssh_access(sandbox)
```

### Preview URLs

```elixir
# Stable per-port URL + auth token (send as x-daytona-preview-token)
{:ok, %{url: url, token: token}} = ExDaytona.Sandbox.preview_url(sandbox, 3000)

# Self-authenticating, expiring, shareable link
{:ok, %{url: signed, token: signed_token}} =
  ExDaytona.Sandbox.signed_preview_url(sandbox, 3000, expires_in_seconds: 3600)

:ok = ExDaytona.Sandbox.expire_signed_preview_url(sandbox, 3000, signed_token)
```

Building a **custom preview proxy**? `ExDaytona.PreviewProxy` wraps the
verification endpoints (is the sandbox public, is this token valid,
resolve a signed token, fetch the signing key). Note: most of those
endpoints require proxy-infrastructure credentials — a regular user API
key gets 403.

### Webhooks

Setting up (Daytona delivers through Svix):

```elixir
{:ok, _} = ExDaytona.Webhooks.initialize(client, org_id)
{:ok, %{url: portal}} = ExDaytona.Webhooks.portal(client, org_id)
# open the portal to add endpoints and pick events
```

Receiving — verify deliveries with the endpoint's `whsec_...` secret and
the **raw** request body:

```elixir
case ExDaytona.Webhooks.verify(raw_body, conn.req_headers, secret) do
  {:ok, event} -> handle_event(event)
  {:error, _} -> send_resp(conn, 400, "bad signature")
end
```

### Declarative builds

Build a sandbox from an image definition instead of a snapshot:

```elixir
image =
  ExDaytona.Image.from("elixir:1.20-alpine")
  |> ExDaytona.Image.run("apk add --no-cache git build-base")
  |> ExDaytona.Image.env(%{"MIX_ENV" => "dev"})
  |> ExDaytona.Image.workdir("/workspace")
  # Local files become COPYs backed by an auto-uploaded build context:
  |> ExDaytona.Image.add_local_file("mix.exs", "/workspace/mix.exs")
  |> ExDaytona.Image.add_local_dir("config", "/workspace/config")

{:ok, sandbox} = ExDaytona.Sandbox.create(client, image: image, timeout: 300_000)

# Or a raw Dockerfile: ExDaytona.Sandbox.create(client, image: "FROM ...")
# Watch the build: ExDaytona.Sandbox.stream_build_logs(sandbox, &IO.write/1)
```

Context uploads speak S3 (SigV4) through the SDK's own HTTP stack — no
AWS dependency; identical content is deduplicated by hash and skipped on
re-upload.

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

See [LICENSE](https://github.com/The-Ixway/ex_daytona/blob/main/LICENSE) for details.

---

**Generated with ❤️ using the [Elixir SDK Generator](https://github.com/houllette/elixir-sdk-generator) template**
