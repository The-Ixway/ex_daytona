# Elixir SDK Generator

[![Template Smoke Test](https://github.com/houllette/elixir-sdk-generator/actions/workflows/template-smoke.yml/badge.svg)](https://github.com/houllette/elixir-sdk-generator/actions/workflows/template-smoke.yml)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**Point this template at an OpenAPI spec and get a production-ready, self-maintaining Elixir SDK.**

One setup script turns this repo into a typed Elixir client for your API — with connection pooling, safe retries, tests, CI, release automation, and an SBOM already wired up. When your API changes, one command (or a weekly bot) regenerates the client.

## How it works

```
your OpenAPI spec ──▶ setup.sh ──▶ regenerate.sh ──▶ published Hex package
                      (once)       (any time the       (tag-driven, automated)
                                    spec changes)
```

**1. Create your repo from this template** — click *Use this template* on GitHub.

**2. Run setup once** (or run the `/setup-sdk` skill in Claude Code, which automates all of this):

```bash
./scripts/setup.sh
```

It asks for your package name, GitHub repo, and where your OpenAPI spec lives — a URL is best, because it enables automatic weekly spec syncing. It then fresh-initializes the README/CHANGELOG/LICENSE for *your* SDK and enables the CI workflows.

**3. Generate and ship:**

```bash
./scripts/regenerate.sh   # validate spec → generate client → test
git push                  # CI takes it from here
```

That's it. Your SDK looks like this to its users:

```elixir
conn = MyAPIClient.Connection.new()
{:ok, %MyAPIClient.Model.User{} = user} = MyAPIClient.Api.Users.get_user(conn, 42)
```

## What your SDK comes with

**The generated client**
- Typed request/response structs for every operation in your spec
- Finch connection pooling, per-request timeouts, telemetry events
- Automatic retries with exponential backoff — *idempotent requests only*, so a POST is never replayed
- Auth support (bearer/basic/OAuth) driven by your spec's security schemes

**Quality gates**
- A test harness (Bypass mock server, Mox, fixtures) that survives regeneration, with a starter test file created per API module
- `mix check` — one command mirroring CI: unused deps, warnings-as-errors, format, `credo --strict`, tests
- CI for tests + coverage threshold, dialyzer, and a compatibility job for the oldest supported Elixir

**Releases, the git-ops way**
- PR titles validated against [Conventional Commits](https://www.conventionalcommits.org); the **Release** workflow derives the version bump (`fix:` → patch, `feat:` → minor, `feat!:` → major), updates the changelog, tags, and publishes to Hex.pm
- A CycloneDX **SBOM** (`bom.cdx.json`) kept in sync by a pre-commit hook, verified in CI, and attached to every release

**Hands-off maintenance**
- **Spec sync**: a weekly workflow checks your spec's source URL and opens a PR — with an API changelog — when it changed
- **Breaking-change detection** on every PR that touches the spec
- Dependabot for Hex packages and GitHub Actions

**AI-assisted workflows**
- `AGENTS.md`/`CLAUDE.md` teach coding agents the golden rule (never edit generated code — fix the spec or templates and regenerate)
- Claude Code skills: `/setup-sdk` mints the SDK (then removes itself), `/regenerate` handles spec updates, diff review, and test upkeep

## Requirements

| Tool | Why |
|---|---|
| Erlang/Elixir (pinned in `.tool-versions`) | building and testing the SDK |
| [OpenAPI Generator](https://openapi-generator.tech/) (`brew install openapi-generator`) + Java 11+ | code generation |
| `jq` | only for non-interactive setup (`--config`) |

## Day-2 workflow

| I want to… | Do this |
|---|---|
| Pull in upstream API changes | merge the weekly spec-sync PR, or `./scripts/regenerate.sh` |
| Add tests for an endpoint | flesh out the starter test in `test/unit/` |
| Check everything before pushing | `mix check` |
| Cut a release | run the **Release** workflow (or `mix git_ops.release`) |
| Customize the generated code | edit `.openapi-generator/templates/`, then regenerate |

## Digging deeper

- **[QUICKSTART.md](QUICKSTART.md)** — step-by-step walkthrough, configuration reference, and troubleshooting
- **[.github/workflows/README.md](.github/workflows/README.md)** — what each CI workflow does and the secrets it needs (`HEX_API_KEY` for publishing)
- **[AGENTS.md](AGENTS.md)** — commands and conventions, for humans and AI agents alike
- **[CONTRIBUTING.md](CONTRIBUTING.md)** · **[CHANGELOG.md](CHANGELOG.md)**

A note on customizing templates: `.openapi-generator/templates/` must always contain the **complete** template set (vendored from openapi-generator 7.23.0) — the elixir generator has no built-in fallback when `templateDir` is set. See the comment in `generator-config.yaml` for re-vendoring instructions.

## For the template itself

This repo tests its own pipeline: the **Template Smoke Test** workflow runs setup → generate → compile → test against the bundled example spec on every push, so template regressions are caught before they reach your SDK.

Generated files credit [openapi-generator](https://openapi-generator.tech/) and this template — please keep the attribution so others can find the tooling.

## License

MIT — see [LICENSE](LICENSE). SDKs you generate are yours, under whatever license you choose at setup.
