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
