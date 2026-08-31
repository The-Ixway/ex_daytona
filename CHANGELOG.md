# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **All template scripting is now Elixir or POSIX shell — python is no
  longer an (undeclared) dependency anywhere**: the CI SBOM drift check is
  `scripts/verify_sbom.exs` (built-in `JSON`, unified diff via `diff -u`),
  the smoke test validates the SBOM with `elixir -e`, validate-spec.sh
  defers syntax checking to the authoritative OpenAPI Generator validation
  instead of a PyYAML fallback, and the spec-patches guide documents
  executable `.exs` patches (with a note on order-preserving JSON via
  OTP's `:json` custom decoders) as the recommended form

### Fixed (from the first production mint — ex_bifrost, ~490 operations)
- `gitUserId`/`gitRepoId` moved to top-level generator config keys — under
  `additionalProperties` the generator ignored them and shipped
  GIT_USER_ID/GIT_REPO_ID placeholders in mix.exs and the SBOM
- Multipart request building in the vendored `request_builder` template:
  Tesla.Multipart requires binary part names (atoms crashed every
  file-upload operation), and `:form` + `:file` parameters now compose into
  one multipart in either order (previously crashed or silently dropped the
  form field); the bundled example spec gained an upload endpoint so the
  smoke test exercises this path permanently
- `@version` extraction anchored to the attribute definition in
  publish.yml, publish.sh, release.yml, and regenerate.sh — the generated
  mix.exs mentions `@version` on three lines, so the unanchored grep made
  every tag-triggered publish fail its version check
- Documented the working first-release path (manual `git tag`, mirroring
  release.yml): `git_ops.release --initial` conflicts with the CHANGELOG
  setup writes, and plain `git_ops.release` with zero tags fails with a
  confusing blank-tag error
- The CI SBOM drift check is now deterministic: it compares only fields
  derived from mix.exs/mix.lock (root component + pkg:hex components +
  pruned dependency graph), retries `mix sbom` against hex.pm fetcher
  timeouts, and prints a normalized diff on failure

### Added (from the first production mint)
- Reflection-driven surface tests shipped with every SDK: every generated
  model builds and decodes, every generated operation round-trips against a
  catch-all mock server (files included), plus unit tests for the
  template-owned Connection/RequestBuilder/Deserializer runtime — measured
  98%+ coverage on the example SDK, so `minimum_coverage` now ships at 90
- `.credo.exs` keeping `--strict` for hand-written code while scoping three
  spec-driven checks (line length, struct field count, predicate names) away
  from generated `lib/`
- `spec-patches/`: ordered, idempotent, executable patches applied to the
  spec after every download and before every regeneration — durable local
  fixes for upstream spec defects that spec-sync would otherwise reintroduce
- Setup now fully cleans up after itself (removes `scripts/setup.sh`,
  `setup.example.json`, and tombstone comments), personalizes the config
  examples with the real package name, drops any stale template SBOM, and
  **rewrites CONTRIBUTING.md and the workflows README for the minted SDK**
  (the template versions contradicted the SDK's toolchain, commit
  conventions, and automated release flow); the template's own CONTRIBUTING
  was updated to match reality too
- Documented the Hex ≥ 2.5 CI key flow (browser-created `api:write` keys;
  `mix hex.user key generate` no longer exists)

### Added (template & tooling)
- **Attribution**: generated files carry a header crediting OpenAPI Generator
  and the [Elixir SDK Generator](https://github.com/houllette/elixir-sdk-generator)
  template; the Hex package links include a "Generated with" entry
- **Module namespace option**: setup now accepts an optional PascalCase
  module name (wired to the generator's `invokerPackage` option); it defaults
  to the camelized package name as before
- **Weekly spec sync**: when the OpenAPI spec is provided as a URL, setup
  records it in `.spec-source` (GitHub `/blob/` URLs are converted to raw
  URLs) and the new `spec-sync.yml` workflow checks it every Monday,
  regenerates on changes, and opens a PR with an oasdiff changelog
- **Agent tooling** (following the elixir_template conventions): `AGENTS.md`
  (with `CLAUDE.md` pointing at it), Claude Code permission allowlist
  (`.claude/settings.json`), and two skills — `/setup-sdk` (interview-driven
  setup + first generation; one-shot, removed by setup.sh once the SDK
  exists) and `/regenerate` (spec refresh, regeneration, diff review,
  test/CHANGELOG updates)
- Repo hygiene: `.editorconfig` and Dependabot (Hex + GitHub Actions, weekly)
- **SBOM automation**: CycloneDX SBOM (`bom.cdx.json`) via `mix sbom`,
  regenerated by a versioned pre-commit hook (`.githooks/`, enabled by
  setup) whenever dependencies change, drift-checked in CI, uploaded as a
  build artifact, and attached to GitHub releases
- **Git-ops release automation**: `git_ops` dev dependency + config,
  `release.yml` workflow (conventional-commit-driven version bump, changelog,
  tag, then dispatches publish), `conventional-commits.yml` PR title check,
  and a `mix check` alias mirroring the CI quality gate; regeneration now
  preserves the released `@version` from mix.exs; publish paths run
  `credo --strict` as a hard gate

### Changed (template & tooling)
- README rewritten around the three-step usage flow; configuration detail
  moved to QUICKSTART.md
- **Setup fresh-initializes SDK release files**: README (with real package
  details, a badge row — Hex version/docs/CI/license — and the module
  namespace filled in by the first generation), CHANGELOG
  (fresh, with the git_ops marker), and LICENSE (SDK owner's copyright) are
  reset by `setup.sh` so new SDKs start their history at zero instead of
  inheriting the template's (`--keep-template-docs` opts out);
  `cleanup-template.sh` was removed as redundant
- Toolchain pinned to Elixir 1.20.2 / OTP 29 in `.tool-versions`; CI reads it
  via `erlef/setup-beam` `version-file` and adds a compatibility job for the
  minimum supported toolchain (Elixir 1.18 / OTP 27, matching the `~> 1.18`
  requirement of generated SDKs)
- CI hardened per elixir_template practices: least-privilege `permissions`,
  concurrency groups, `mix deps.unlock --check-unused`, `mix hex.audit`, and
  `mix dialyzer --format github`
- Confirmed the vendored generator templates match the latest
  openapi-generator release (7.23.0); no elixir-generator changes upstream

### Fixed
- SDK generation now works end-to-end: removed the invalid `library: tesla`
  generator option, vendored the complete elixir template set (the elixir
  generator does not fall back to built-in templates when `templateDir` is
  set), and fixed an invalid Mustache tag in `mix.exs.mustache`
- `application.ex.mustache` is now actually rendered (registered as an extra
  supporting file via the `files:` section of `generator-config.yaml`); the
  generated app previously failed to boot because the Application module never
  existed
- Finch pool configuration now uses keyword lists (Finch rejects maps)
- Generated API calls work at runtime: the connection template keeps the stock
  `request/2`, auth support, and encode-only JSON middleware (the previous
  decode-in-middleware caused a crash on every typed response)
- Retries are now limited to idempotent HTTP methods; POSTs are never replayed
- `test/support` modules are compiled in the test env (`elixirc_paths`), and
  the placeholder tests were replaced with real, passing tests
- `config/test.exs` no longer uses the removed `:logger` `backends` option
- `setup.sh` and `validate-spec.sh` no longer die mid-run due to bash
  arithmetic under `set -e`; regeneration no longer fails on the first run
- CI workflows: fixed invalid YAML in `test.yml`, replaced dead/archived
  action versions, fixed `publish.yml` running `mix docs` under
  `MIX_ENV=prod`, and aligned Elixir versions with `mix.exs`

### Added
- `template-smoke.yml`: an end-to-end CI test of the template itself
  (setup → generate → compile → test); removed by `setup.sh` in SDK repos
- Non-interactive setup: `./scripts/setup.sh --config file.json` (see
  `setup.example.json`) and `--no-git`
- `.gitignore`, `LICENSE`, `.tool-versions`, `coveralls.json` (configurable
  coverage threshold), and starter test templates per generated API module
- Backup rotation for `.backup/` (5 most recent kept)

### Changed
- Coverage threshold is now configured in `coveralls.json` (default 0 so a
  fresh SDK passes CI; raise it as you add tests)
- Breaking-change detection: spec-level oasdiff check is the only failing
  gate; the removed-function grep is informational
- Setup no longer prompts for module name (the generator derives it from the
  package name), author, or Hex organization
- `setup.json` (unused JSON schema) replaced by `setup.example.json`
- Test helpers use Elixir's built-in `JSON` module instead of the undeclared
  Jason dependency; removed the Phoenix-specific `sobelow` dependency

## [0.1.0] - 2025-10-06

### Added
- Initial template setup
- OpenAPI SDK generation support
- Custom Mustache templates for production-ready code
- Connection pooling with Finch
- Automatic retry logic with exponential backoff
- Telemetry integration
- Comprehensive test infrastructure
- GitHub Actions workflows for CI/CD
- Auto-regeneration workflow
- Breaking changes detection
- Hex.pm publishing workflow
- Interactive setup script
- Code coverage enforcement
- Example unit and integration tests

### Documentation
- Comprehensive README with usage examples
- Contributing guidelines
- Project structure documentation
- Development workflow guide
