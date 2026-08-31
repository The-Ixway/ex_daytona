# Agent Guidelines

## Project overview

`ex_daytona` is an **unofficial** Elixir SDK for the
[Daytona](https://www.daytona.io) AI sandbox platform, generated with the
[Elixir SDK Generator](https://github.com/houllette/elixir-sdk-generator)
template. Module namespace: `ExDaytona` (pinned via `invokerPackage` in
`generator-config.yaml` — don't let the generator re-derive it from the
spec title). For ongoing spec/template changes use the `/regenerate` skill.

**Spec source is multi-document.** Daytona publishes three separate specs
(no combined file), so this repo diverges from the template's single-URL
`.spec-source` flow: `scripts/fetch-spec.sh` downloads all three, converts
the Swagger 2.0 ones to OpenAPI 3.0 (`npx swagger2openapi`), verifies there
are no cross-spec name collisions, and merges them deterministically into
`openapi-spec.yaml`. The source URLs live in that script, not `.spec-source`
(the spec-sync workflow was adapted to call it). The three APIs keep their
own base URLs — see the README's "Base URLs" section:

- main platform API → `https://app.daytona.io/api` (the configured default)
- toolbox API → `{toolboxProxyUrl}/{sandboxId}`, per sandbox
  (`ExDaytona.Toolbox.connection/2` builds this; template
  `toolbox.ex.mustache`)
- analytics API → `https://analytics.app.daytona.io`
  (`ExDaytona.Analytics.connection/1`; template `analytics.ex.mustache`)

Upstream operationId defects (missing ids on analytics paths, leaked NestJS
controller prefixes) are fixed durably in
`spec-patches/10-clean-operation-ids.sh` — extend that patch for future
naming defects rather than accepting ugly generated function names.
`scripts/post-generate.sh` prunes lib/ files the generator's FILES manifest
no longer lists, so renamed-away modules don't linger.

## Commands

| Task | Command |
| --- | --- |
| Refresh spec from upstream (fetch + merge) | `./scripts/fetch-spec.sh` |
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
`./scripts/regenerate.sh` run — with ONE exception: `lib/ex_daytona/sdk/`
is the **hand-written facade layer** (`ExDaytona.Client`, `ExDaytona.Error`,
`ExDaytona.Sandbox`). It is listed in `.openapi-generator-ignore`, exempted
from orphan pruning, and edited directly like any normal code. The facade
wraps the generated `ExDaytona.Api.*`/`Model.*` modules with idiomatic
Elixir (snake_case options, normalized `{:error, %ExDaytona.Error{}}`
returns); the generated modules remain the escape hatch for the long tail
of endpoints. Everywhere else, never hand-edit generated files; the fix
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
