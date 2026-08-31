# Quick Start Guide

Get your SDK up and running in minutes!

## Prerequisites

- Erlang/Elixir as pinned in `.tool-versions` (Elixir 1.20.2 / OTP 29)
- Java 11+ (required by OpenAPI Generator)
- OpenAPI Generator: `brew install openapi-generator` or `npm install -g @openapitools/openapi-generator-cli`
- Git
- `jq` (only for non-interactive setup)

## Step 1: Clone or Use Template

### Option A: Use GitHub Template

1. Click "Use this template" on GitHub
2. Name your new repository
3. Clone your new repository

### Option B: Clone Directly

```bash
git clone https://github.com/your-username/elixir-sdk-generator.git my-sdk
cd my-sdk
```

## Step 2: Run Setup

```bash
# Interactive
./scripts/setup.sh

# Or non-interactive — copy setup.example.json, edit it, then:
./scripts/setup.sh --config my-setup.json
```

You'll be asked for:

- **Package name**: `my_api_client` (lowercase, underscores)
- **Module namespace**: optional PascalCase (e.g. `MyAPIClient`); derived
  from the package name when left blank
- **Description**: optional; falls back to the spec's `info.description`
- **GitHub info**: username and repo name
- **Base URL**: API base URL (optional)
- **OpenAPI spec**: path or URL (optional; keeps the bundled example spec).
  A URL is recorded in `.spec-source` and enables the weekly spec-sync
  workflow that opens a PR when the upstream spec changes.
- **License**: SPDX id, default `MIT`

Setup fresh-initializes your SDK's release files (README with a badge row —
Hex version, docs, CI, license — CHANGELOG with the release-automation
marker, and LICENSE, starting your SDK's history at zero instead of
inheriting the template's; the Hex badges activate on your first publish),
enables the GitHub Actions workflows,
and removes template-only artifacts (QUICKSTART.md, the smoke-test workflow,
and the one-shot `/setup-sdk` skill). In Claude Code you can run the
`/setup-sdk` skill instead — it automates this step and the next, then cleans
itself up, leaving the `/regenerate` skill for ongoing maintenance.

## Step 3: Generate SDK

```bash
./scripts/regenerate.sh
```

This validates the spec, generates the SDK, creates starter test files for
each API module, installs dependencies, formats everything, and runs the
tests. All checks pass on a fresh generation:

```bash
mix test
mix credo --strict
mix dialyzer
```

## Step 4: Add Real Tests

The template ships reflection-driven surface tests that already cover the
whole generated surface (every model decodes, every operation round-trips
against a mock server), which is what makes the 90% coverage floor pass out
of the box. For behavior-specific coverage, flesh out the per-module starter
tests in `test/unit/` using the mock server:

```elixir
test "gets a user", %{bypass: bypass, conn: conn} do
  MockServer.expect_get(bypass, "/users/1", 200, %{id: 1, name: "Test"})
  assert {:ok, %MySDK.Model.User{id: 1}} = Users.get_user(conn, 1)
end
```

The coverage floor lives in `coveralls.json` (`minimum_coverage: 90`);
raise it further as hand-written tests grow.

## Step 5: Configure GitHub Actions

Add the `HEX_API_KEY` secret: create a key at hex.pm → Dashboard → Keys with
`api:write` permission, then `gh secret set HEX_API_KEY`. (Hex ≥ 2.5 removed
`mix hex.user key generate` — keys are created in the browser now.) See
`.github/workflows/README.md` for the full workflow documentation.

## Step 6: Make Your First Release

Releases are automated with git_ops + conventional commits:

1. Merge PRs with conventional titles (`feat: ...`, `fix: ...` — enforced by
   the conventional-commits workflow; use squash merges)
2. Run the **Release** workflow from the Actions tab. The first run tags the
   current `@version`; later runs derive the bump from commit history,
   update CHANGELOG.md, tag, and trigger publishing to Hex.pm
3. Or locally — the **first** release must tag manually (mirroring the
   workflow):

   ```bash
   git tag -a "v$(grep -E '^\s*@version "' mix.exs | head -1 | sed -E 's/.*"([^"]+)".*/\1/')" -m "First release"
   git push --follow-tags
   ```

   Every release after that: `mix git_ops.release`, then
   `git push --follow-tags`.

   > **Why not `mix git_ops.release --initial`?** It refuses to run when
   > CHANGELOG.md already exists (and setup writes one), while plain
   > `git_ops.release` with zero tags fails with a confusing blank-tag
   > error ("The tag  was found in the tag list but does not exist
   > locally"). Manual first tag avoids both.

Before releasing, run the full quality gate locally:

```bash
mix check
```

Each release automatically gets the CycloneDX SBOM (`bom.cdx.json`) attached.

## Configuration Reference

### Connection options

```elixir
conn = MySDK.Connection.new(
  base_url: "https://api.example.com",     # override the configured base URL
  timeout: 60_000,                          # per-request timeout (ms)
  retry: [max_retries: 5, delay: 200, max_delay: 10_000],
  middleware: [{Tesla.Middleware.Logger, []}]
)

conn = MySDK.Connection.new(retry: false)   # disable retries
```

### Retry semantics

Retries use exponential backoff and are **limited to idempotent HTTP methods**
(GET, HEAD, OPTIONS, PUT, DELETE) on status 408/429/5xx or transport errors —
a POST is never replayed automatically. Override with a custom predicate:

```elixir
conn = MySDK.Connection.new(retry: [should_retry: fn result, env, _ctx -> ... end])
```

### Runtime configuration

```elixir
# config/runtime.exs
config :my_api_client,
  base_url: System.get_env("API_BASE_URL", "https://api.example.com"),
  pool_size: String.to_integer(System.get_env("HTTP_POOL_SIZE", "25")),
  pool_count: 1,
  connect_timeout: 5_000
```

### SBOM

A CycloneDX SBOM lives at `bom.cdx.json` and is committed. The pre-commit
hook (enabled by setup via `git config core.hooksPath .githooks`) regenerates
it whenever `mix.exs`/`mix.lock` change; CI fails if it drifts, and the
publish workflow attaches it to every GitHub release. Regenerate manually
with:

```bash
mix sbom
```

## Common Tasks

### Fix a Defect in the Upstream Spec

Don't edit `openapi-spec.yaml` by hand — spec-sync would reintroduce the
defect on its next run. Add an executable, idempotent patch script to
`spec-patches/` instead (see `spec-patches/README.md`); it is applied after
every download and before every regeneration.

### Update API from New Spec

```bash
cp /path/to/new/spec.yaml openapi-spec.yaml
./scripts/regenerate.sh
git diff        # review changes
git add . && git commit -m "Update API from spec v2.0"
```

### Configure Runtime Settings

```elixir
# config/runtime.exs
config :my_api_client,
  base_url: System.get_env("API_BASE_URL", "https://api.example.com"),
  pool_size: String.to_integer(System.get_env("HTTP_POOL_SIZE", "25"))
```

### Customize Generated Code

Edit templates in `.openapi-generator/templates/` and rerun
`./scripts/regenerate.sh`. Note that the directory must always contain the
**complete** template set — the elixir generator does not fall back to its
built-in templates. See the README's "Custom Templates" section.

## Troubleshooting

### OpenAPI Generator Not Found

```bash
brew install openapi-generator          # macOS/Linux (recommended)
npm install -g @openapitools/openapi-generator-cli
docker pull openapitools/openapi-generator-cli
```

### Tests Failing After Regeneration

1. Check if the API changed (see the breaking-changes workflow output)
2. Update test expectations
3. Add tests for new endpoints

### Coverage Below Threshold

```bash
mix coveralls.html && open cover/excoveralls.html
```

Add tests for uncovered code, or adjust `minimum_coverage` in `coveralls.json`.

### Format Errors

```bash
mix format
```

## Resources

- [OpenAPI Specification](https://swagger.io/specification/)
- [OpenAPI Generator Docs](https://openapi-generator.tech/docs/generators/elixir)
- [Elixir Tesla](https://github.com/elixir-tesla/tesla)
- [Finch HTTP Client](https://github.com/sneako/finch)
- [Hex.pm Publishing Guide](https://hex.pm/docs/publish)
