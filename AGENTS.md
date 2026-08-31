# Agent Guidelines

## About this repo

This repo starts life as the [Elixir SDK Generator](https://github.com/houllette/elixir-sdk-generator)
*template*: it generates an Elixir SDK from an OpenAPI specification. If
`generator-config.yaml` still contains `{{PACKAGE_NAME}}` placeholders, the
project hasn't been configured yet — run `./scripts/setup.sh` (or the
`/setup-sdk` skill, which is one-shot and removed by setup) first, and don't
try to run mix tasks (there is no `mix.exs` until the first generation). Once
configured and generated, delete this paragraph and fill in the "Project
overview" section below. For ongoing spec/template changes use the
`/regenerate` skill.

## Project overview

<!-- After setup: one paragraph on which API this SDK wraps, the module
     namespace, and anything non-obvious. -->

## Commands

| Task | Command |
| --- | --- |
| Regenerate SDK from spec | `./scripts/regenerate.sh` |
| Validate the OpenAPI spec | `./scripts/validate-spec.sh` |
| Install deps | `mix deps.get` |
| Compile (warnings are errors in CI) | `mix compile --warnings-as-errors` |
| Run all tests | `mix test` |
| Run one test file | `mix test test/path/to/file_test.exs` |
| Run tests with coverage | `mix coveralls` (threshold in `coveralls.json`) |
| Full quality gate (mirrors CI) | `mix check` |
| Format | `mix format` |
| Lint | `mix credo --strict` |
| Type check | `mix dialyzer` |
| Generate/refresh the SBOM | `mix sbom` (writes `bom.cdx.json`) |
| Cut a release (version + changelog + tag) | `mix git_ops.release` (or the Release workflow) — **first release ever**: tag manually (`git tag -a v0.1.0`); `git_ops.release` needs a previous tag and `--initial` conflicts with the existing CHANGELOG.md |
| Publish to Hex.pm | `./scripts/publish.sh` |

## The golden rule: generated vs. persistent files

`lib/` and `mix.exs` are **generated** — they are overwritten by every
`./scripts/regenerate.sh` run. Never hand-edit them to fix a problem; the fix
belongs in one of the persistent sources:

- `openapi-spec.yaml` — the API contract (or its upstream source recorded in
  `.spec-source`); fix upstream spec defects with idempotent scripts in
  `spec-patches/`, never by hand-editing the spec (spec-sync re-downloads it)
- `.openapi-generator/templates/` — the COMPLETE vendored Mustache template
  set (the elixir generator does not fall back to built-in templates, so
  never delete files from this directory; see `generator-config.yaml` for
  re-vendoring instructions)
- `scripts/post-generate.sh` — post-generation transformations
- `generator-config.yaml` — generator options
- Everything in `.openapi-generator-ignore` (config, tests, scripts, docs,
  workflows) is protected and safe to edit

After changing a template or the spec, run `./scripts/regenerate.sh` and
review the diff.

## Conventions

- **Format before committing.** CI enforces `mix format --check-formatted`.
- **No compiler warnings.** CI compiles with `--warnings-as-errors`; fix
  warnings rather than working around them (in templates, not in `lib/`).
- **Test with the harness in `test/support/`.** `use TestCase` (brings in
  Mox helpers), `MockServer` (Bypass-backed mock HTTP server), and `Fixtures`.
  New endpoints get a starter test in `test/unit/` from post-generation —
  flesh those out. Use `async: true` unless a test shares global state.
- **Retries are idempotent-only by design.** The generated `Connection`
  never retries POSTs; don't change that default in the template without a
  very good reason.
- **Raise the coverage bar as tests are added** via `minimum_coverage` in
  `coveralls.json`.
- **Typespecs on public functions**; Dialyzer runs in CI.
- **Use Conventional Commit messages** (`feat:`, `fix:`, `chore:`, `feat!:`
  for breaking changes) — release automation derives version bumps and the
  CHANGELOG from them via git_ops. `@version` in mix.exs is the version
  source of truth; regeneration preserves it (never edit `packageVersion` in
  `generator-config.yaml` by hand).
- **Run `mix check` before pushing** — it mirrors the CI gate (unused deps,
  warnings-as-errors, format, credo strict, tests, plus an informational
  hex.audit).
- **The SBOM (`bom.cdx.json`) is committed.** The pre-commit hook (enabled
  via `git config core.hooksPath .githooks`, done by setup) regenerates it
  when mix.exs/mix.lock change; CI fails if it drifts. Never edit it by hand.

## Versions

Erlang/Elixir versions are pinned in `.tool-versions` (used by asdf/mise
locally and by `erlef/setup-beam` in CI). Bump versions there, nowhere else.
The vendored generator templates track openapi-generator 7.23.0.
