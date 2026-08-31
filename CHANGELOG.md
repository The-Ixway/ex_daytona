# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are cut with `mix git_ops.release` (or the Release workflow), which
inserts new sections below this marker:

<!-- changelog -->

## [Unreleased]

### Added
- Initial SDK generated from Daytona's OpenAPI specifications (main
  platform, toolbox, and analytics APIs merged by `scripts/fetch-spec.sh`)
- `ExDaytona.Toolbox.connection/2` — builds a connection to a sandbox's
  toolbox API from its `toolboxProxyUrl`
- `ExDaytona.Analytics.connection/1` — builds a connection to the analytics
  API (base URL configurable via `config :ex_daytona, :analytics_base_url`)
- High-level SDK facade (hand-written, survives regeneration):
  `ExDaytona.Client` (API-key auth, `DAYTONA_API_KEY` fallback),
  `ExDaytona.Error` (all generated-client failure shapes normalized to
  `{:error, %ExDaytona.Error{}}`), and `ExDaytona.Sandbox`
  (create/get/list/start/stop/delete with state waiting, `exec/3`,
  `write_file/3`, `read_file/2`, `list_files/2`)
- `ExDaytona.Session` — persistent shell sessions with shared state:
  synchronous `run/2`, asynchronous `run_async/2` + `await/3`, raw
  `logs/2`, and real-time `stream_logs/4` (incremental chunked-HTTP
  streaming)
- `ExDaytona.Git` — clone/status/branches/create_branch/checkout/add/
  commit/push/pull/history inside a sandbox, with credential options for
  authenticated remotes
- `ExDaytona.Sandbox.build_logs/1` and `stream_build_logs/3` — fetch or
  follow a building sandbox's build logs
- `ExDaytona.Pty` — interactive terminals: create/resize/list/delete plus
  a real websocket connection (`connect/2`, `send_input/2`) built on the
  new `ExDaytona.WebSocket` client (Mint.WebSocket)
- SSH access on the sandbox facade: `ssh_access/2`, `revoke_ssh_access/1`,
  `validate_ssh_access/2`
- Preview URLs on the sandbox facade: `preview_url/2`,
  `signed_preview_url/3`, `expire_signed_preview_url/3`; plus
  `ExDaytona.PreviewProxy` verification helpers for running a custom
  preview proxy
- `ExDaytona.Webhooks` — organization webhook setup (initialize, status,
  Svix app portal access, endpoint refresh) and `verify/4` for receiving:
  Svix/Standard-Webhooks HMAC signature verification with timestamp
  tolerance
- `ExDaytona.Image` — declarative image DSL (`from/run/env/workdir/user/
  label/expose/entrypoint/cmd` + raw Dockerfiles) wired into
  `ExDaytona.Sandbox.create(client, image: ...)` for building sandboxes
  from Dockerfiles
- Local build contexts: `ExDaytona.Image.add_local_file/3` and
  `add_local_dir/3` copy local files into declaratively built images —
  contexts are content-hashed, tarred, and uploaded to Daytona's object
  storage automatically on create (`ExDaytona.ObjectStorage`), with a
  dependency-free AWS SigV4 signer pinned by AWS's published test
  vectors

### Fixed
- Request bodies no longer send explicit JSON `null`s for unset optional
  model fields — the Daytona API rejects them (500) where an empty object
  succeeds; models now omit nil fields when encoding

### Changed
- Cleaned generated function names via a spec patch: analytics endpoints
  that ship without operationIds get descriptive ones
  (`get_organization_usage_aggregated/5` instead of
  `organization_organization_id_usage_aggregated_get/5`), and leaked NestJS
  controller prefixes are stripped (`Health.check/2` instead of
  `Health.health_controller_check/2`)
