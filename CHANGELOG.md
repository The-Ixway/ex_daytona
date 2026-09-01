# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are cut with `mix git_ops.release` (or the Release workflow), which
inserts new sections below this marker:

<!-- changelog -->

## [v0.3.0](https://github.com/The-Ixway/ex_daytona/releases/tag/v0.3.0) - 2026-09-01

Quota, usage, and metering primitives for applications that build their
own per-end-user limit or billing logic on top of Daytona's org-level
enforcement. Read primitives only — the SDK ships no tenant policy.

### Added
- `ExDaytona.Quota` — normalized org quota truth: `overview/2`
  (snapshot/volume gauges + per region × sandbox-class used-vs-total for
  cpu/memory/disk/gpu with per-sandbox maxima), `headroom/3` (remaining
  capacity per dimension, with known-combination hints on miss), and
  `limits/2` (org per-sandbox maxima, secret quota, and
  create/lifecycle/API rate limits).
- Metering primitives on `ExDaytona.Platform` (analytics API, connection
  derived automatically): `usage_aggregated/4`, `usage_per_sandbox/4`
  (the per-sandbox CPU-seconds/RAM-GB-seconds/disk/price rows that
  application-defined scopes roll up), and `usage_chart/5`.
- `ExDaytona.Sandbox.list/2` accepts `labels:` as a map (JSON-encoded
  into the server-side filter) — the attribution primitive for scoping
  sandboxes to application-defined identities via labels set at create
  time. Pre-encoded strings still pass through.

### Live-verified contracts
- The analytics metering endpoints accept plain API keys — verified
  against production.
- `Quota.limits/2` reads the organization record, which is JWT-gated
  (401 with API keys, documented); API-key callers get the per-sandbox
  maxima from `Quota.overview/2` instead.

## [v0.2.0](https://github.com/The-Ixway/ex_daytona/releases/tag/v0.2.0) - 2026-09-01

Production-hardening release: constant-memory transfer, structured
bounded log streaming, response/rate-limit metadata, retry correctness,
credential redaction, a completed security facade, and injectable
streaming transports. No breaking changes to 0.1.0 call sites.

### Added
- **Constant-memory file transfer**: `ExDaytona.FS.upload_stream/4`,
  `upload_file/4`, `download_stream/4`, and `download_file/4` — lazy
  multipart uploads from Enumerables/IO devices/files, consumer-driven
  downloads, `max_bytes`/idle/overall limits, caller cancellation,
  incremental SHA-256 with optional verification, and atomic
  temp-file-then-rename downloads that never clobber an existing
  destination. Existing small-file helpers unchanged (buffering now
  documented).
- **Structured log streaming**: `ExDaytona.LogStream` +
  `ExDaytona.Session.open_log_stream/3` — pull-based (`next/2`,
  `collect/2`), owner-monitored, bounded (buffer/frame caps with
  explicit overflow errors), with idle and overall timeouts and no
  silent reconnect. Decodes the provider's stdout/stderr channel-marker
  protocol into separate `:stdout`/`:stderr` events; daemons that stream
  unlabeled output (the production daemon at release time — verified
  live) yield merged `{:output, bytes}` events instead of dropping data. `Session.stream_logs/4`
  remains as the documented merged-output HTTP path and gains `:halt`
  cancellation and a `:deadline`.
- **Response metadata**: `response: :full` on every generated operation
  returns `%ExDaytona.Response{}` (status, normalized headers, request
  id, rate-limit state, parsed Retry-After, transport retry count).
  `ExDaytona.Error` carries the same fields on every facade error, plus
  an `outcome` (`:definite` | `:unknown`) that refuses to claim a
  definite result for non-idempotent requests lost in transport.
- **Security facade**: `Sandbox.create/2` now exposes every
  CreateSandbox field (`domain_allow_list`, vault `secrets` bindings,
  `auto_pause_interval`, `gpu_type`, `spot`, `linked_sandbox`,
  `outbound_proxy_url`, `otel_endpoint_override`);
  `Sandbox.update_network_settings/2` for runtime policy;
  `ExDaytona.Secrets` (manage, bind, resolve — resolved values redacted
  under inspect); `ExDaytona.Platform` (regions, sandbox classes,
  snapshots, usage/quota).
- **Injectable streaming transports**: `ExDaytona.Transport` behaviours
  for streaming HTTP and websockets, selected via
  `Client.new(transports: [...])` and carried into every derived stream —
  built for deterministic failure simulation in tests.
- Dedicated Finch pool (`ExDaytona.Finch.Stream`, tunable via
  `:stream_pool_size`/`:stream_pool_count`) isolates long-lived streams
  and bulk transfers from lifecycle/control requests.

### Changed
- **Credential redaction everywhere**: every generated model, the
  client, errors, and the new SSH/preview/storage result structs render
  credential-shaped fields as `"[REDACTED]"` under `inspect/1`; error
  details/headers are deep-sanitized; URLs in messages have signed query
  parameters scrubbed; telemetry no longer carries the Tesla client (and
  its embedded bearer token). Note: field-name matching intentionally
  over-redacts (e.g. pagination `nextToken` cursors render redacted).
- Retries now forward `jitter_factor` and honor `Retry-After` on safe
  (idempotent) retries **by default** (`use_retry_after_header: true`,
  capped by `max_delay`); POSTs remain never auto-retried.
- `Sandbox.ssh_access/2`, `preview_url/2`, `signed_preview_url/3`, and
  `ObjectStorage.push_access/1` return dedicated structs with redacted
  inspection — pattern-matching on the previous map shapes continues to
  work.

### Migration notes
- No call-site changes required. If you pattern-matched telemetry
  metadata's `env.__client__`, it is now `nil` (credential hygiene).
- If your handlers relied on retries NOT honoring `Retry-After`, pass
  `retry: [use_retry_after_header: false]`.

## [v0.1.0](https://github.com/The-Ixway/ex_daytona/releases/tag/v0.1.0) - 2026-08-31

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
- `ExDaytona.FS` — the full file-system facade: `write_file`/`read_file`/
  `write_files`, local `upload`/`download`, `mkdir`, `stat`, `delete`
  (recursive), `move`, `chmod`, glob `search`, content `grep`, and text
  `replace` with per-file results (the `Sandbox` file helpers delegate
  here)
- `ExDaytona.Sandbox.run_code/3` — stateless code snippets (Python/
  JavaScript/TypeScript) with argv/env/timeout and chart artifacts
- `ExDaytona.CodeInterpreter` — stateful Python execution over the
  interpreter websocket: state persists between `run/3` calls, isolated
  contexts (`create_context`/`list_contexts`/`delete_context`), streaming
  `on_stdout`/`on_stderr`/`on_error` callbacks, and structured execution
  errors
- `ExDaytona.Session.send_input/3` (with a retry for the daemon's
  stdin-pipe startup race and a `suppress_input_echo` option on
  `run_async/3`), plus `entrypoint/1` and `entrypoint_logs/1`
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
