#!/usr/bin/env bash
set -euo pipefail

# Elixir SDK Generator - Setup Script
# Initializes a new SDK project from this template.
#
# Usage:
#   ./scripts/setup.sh                       # interactive
#   ./scripts/setup.sh --config setup.json   # non-interactive (requires jq)
#   ./scripts/setup.sh --no-git              # skip git initialization
#   ./scripts/setup.sh --keep-template-docs  # don't reset README/CHANGELOG/etc.
#
# See setup.example.json for the config file format.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $*"; }

CONFIG_FILE=""
SKIP_GIT=0
KEEP_TEMPLATE_DOCS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:-}"
      shift 2
      ;;
    --no-git)
      SKIP_GIT=1
      shift
      ;;
    --keep-template-docs)
      KEEP_TEMPLATE_DOCS=1
      shift
      ;;
    -h|--help)
      grep '^#' "$0" | head -12
      exit 0
      ;;
    *)
      echo_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Escape a string for use as a sed replacement (with | as delimiter)
escape_replacement() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# Convert a PascalCase module name to snake_case, matching the underscore
# algorithm openapi-generator uses for the lib/ directory (MyAPIClient ->
# my_api_client).
underscore() {
  printf '%s' "$1" \
    | sed -E 's/([A-Z]+)([A-Z][a-z])/\1_\2/g; s/([a-z0-9])([A-Z])/\1_\2/g' \
    | tr '[:upper:]' '[:lower:]'
}

# Check dependencies
check_dependencies() {
  echo_info "Checking dependencies..."

  if [[ -n "$CONFIG_FILE" ]] && ! command -v jq &> /dev/null; then
    echo_error "jq is required for --config mode. Please install it and try again."
    exit 1
  fi

  if ! command -v openapi-generator &> /dev/null \
    && ! command -v npx &> /dev/null \
    && ! command -v docker &> /dev/null; then
    echo_warn "OpenAPI Generator not found (looked for openapi-generator, npx, docker)."
    echo_warn "Install it before running ./scripts/regenerate.sh:"
    echo_warn "  brew install openapi-generator"
  fi

  echo_info "Dependency check complete."
}

# Guard against running setup twice: the placeholders can only be replaced once.
check_not_already_configured() {
  if ! grep -q '{{PACKAGE_NAME}}' "$PROJECT_ROOT/generator-config.yaml"; then
    echo_error "This project appears to be configured already"
    echo_error "(no {{PACKAGE_NAME}} placeholder left in generator-config.yaml)."
    echo_error "Edit generator-config.yaml directly to change settings."
    exit 1
  fi
}

# Read configuration from a JSON file
read_config_file() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo_error "Config file not found: $CONFIG_FILE"
    exit 1
  fi

  PACKAGE_NAME=$(jq -r '.package_name // empty' "$CONFIG_FILE")
  MODULE_NAME=$(jq -r '.module_name // empty' "$CONFIG_FILE")
  DESCRIPTION=$(jq -r '.description // empty' "$CONFIG_FILE")
  GIT_USER=$(jq -r '.git_user // empty' "$CONFIG_FILE")
  GIT_REPO=$(jq -r '.git_repo // empty' "$CONFIG_FILE")
  BASE_URL=$(jq -r '.base_url // empty' "$CONFIG_FILE")
  OPENAPI_SPEC_PATH=$(jq -r '.openapi_spec_path // empty' "$CONFIG_FILE")
  LICENSE_ID=$(jq -r '.license // "MIT"' "$CONFIG_FILE")

  echo_info "Loaded configuration from $CONFIG_FILE"
}

# Prompt user for configuration
prompt_config() {
  echo ""
  echo "================================================"
  echo "  Elixir SDK Generator - Initial Setup"
  echo "================================================"
  echo ""
  echo "This script will configure your new SDK project."
  echo ""

  read -rp "Package name (e.g., my_api_client): " PACKAGE_NAME
  read -rp "Module name (PascalCase, blank = derived from package name): " MODULE_NAME
  read -rp "Description (blank = use the spec's description): " DESCRIPTION
  read -rp "GitHub username/org: " GIT_USER
  read -rp "GitHub repo name: " GIT_REPO
  read -rp "API base URL (optional, can be configured later): " BASE_URL
  read -rp "Path or URL to OpenAPI spec (blank = keep openapi-spec.yaml): " OPENAPI_SPEC_PATH
  read -rp "License SPDX id [MIT]: " LICENSE_ID
  LICENSE_ID=${LICENSE_ID:-MIT}

  echo ""
}

# Validate configuration values
validate_config() {
  if [[ ! $PACKAGE_NAME =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo_error "Invalid package name '$PACKAGE_NAME'. Must be lowercase with underscores."
    exit 1
  fi

  if [[ -n "$MODULE_NAME" ]] && [[ ! $MODULE_NAME =~ ^[A-Z][A-Za-z0-9]*$ ]]; then
    echo_error "Invalid module name '$MODULE_NAME'. Must be PascalCase (e.g. MyAPIClient)."
    exit 1
  fi

  if [[ -z "$GIT_USER" || -z "$GIT_REPO" ]]; then
    echo_error "GitHub username and repo name are required."
    exit 1
  fi

  # The generated lib/ directory follows the underscored module namespace
  # (or the package name when no module name is given).
  if [[ -n "$MODULE_NAME" ]]; then
    LIB_DIR=$(underscore "$MODULE_NAME")
    echo_info "Package name: $PACKAGE_NAME, module namespace: $MODULE_NAME (lib/$LIB_DIR)"
  else
    LIB_DIR="$PACKAGE_NAME"
    echo_info "Package name: $PACKAGE_NAME (module namespace derived by the generator)"
  fi
}

# Apply configuration to files
apply_config() {
  echo_info "Applying configuration..."

  # Fetch the OpenAPI spec FIRST: it is the only step that can fail on
  # external factors (bad path, unreachable URL), and it must fail before any
  # placeholders are replaced so setup can simply be re-run.
  if [[ -z "$OPENAPI_SPEC_PATH" ]]; then
    echo_info "Keeping existing openapi-spec.yaml"
  elif [[ -f "$OPENAPI_SPEC_PATH" ]]; then
    cp "$OPENAPI_SPEC_PATH" "$PROJECT_ROOT/openapi-spec.yaml"
    echo_info "Copied OpenAPI spec to openapi-spec.yaml"
  elif [[ "$OPENAPI_SPEC_PATH" =~ ^https?:// ]]; then
    # Convert GitHub blob URLs to raw URLs so curl gets the file, not HTML
    local spec_url="$OPENAPI_SPEC_PATH"
    if [[ "$spec_url" =~ ^https://github\.com/([^/]+)/([^/]+)/blob/(.+)$ ]]; then
      spec_url="https://raw.githubusercontent.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
      echo_info "Converted GitHub blob URL to raw URL: $spec_url"
    fi

    echo_info "Downloading OpenAPI spec from $spec_url"
    if ! curl -fsSL "$spec_url" -o "$PROJECT_ROOT/openapi-spec.yaml"; then
      echo_error "Failed to download the OpenAPI spec from $spec_url"
      echo_error "Nothing has been modified — fix the URL and re-run setup."
      exit 1
    fi

    # Record the source URL so the spec-sync workflow can check for updates
    echo "$spec_url" > "$PROJECT_ROOT/.spec-source"
    echo_info "Recorded spec source in .spec-source (used by the weekly spec-sync workflow)"
  else
    echo_error "Invalid OpenAPI spec path: $OPENAPI_SPEC_PATH"
    exit 1
  fi

  # Apply any local spec patches (see spec-patches/README.md)
  if [[ -x "$SCRIPT_DIR/apply-spec-patches.sh" ]]; then
    "$SCRIPT_DIR/apply-spec-patches.sh" "$PROJECT_ROOT/openapi-spec.yaml"
  fi

  local generator_config="$PROJECT_ROOT/generator-config.yaml"
  local pkg desc user repo license lib_dir
  pkg=$(escape_replacement "$PACKAGE_NAME")
  desc=$(escape_replacement "$DESCRIPTION")
  user=$(escape_replacement "$GIT_USER")
  repo=$(escape_replacement "$GIT_REPO")
  license=$(escape_replacement "$LICENSE_ID")
  lib_dir=$(escape_replacement "$LIB_DIR")

  # When no module name was given, drop the invokerPackage line (and its
  # comment) so the generator derives the namespace from the package name.
  if [[ -z "$MODULE_NAME" ]]; then
    sed -i.bak '/invokerPackage:/d' "$generator_config"
  else
    local mod
    mod=$(escape_replacement "$MODULE_NAME")
    sed -i.bak "s|{{MODULE_NAME}}|$mod|g" "$generator_config"
  fi
  rm -f "$generator_config.bak"

  sed -i.bak \
    -e "s|{{PACKAGE_NAME}}|$pkg|g" \
    -e "s|{{LIB_DIR}}|$lib_dir|g" \
    -e "s|{{DESCRIPTION}}|$desc|g" \
    -e "s|{{GIT_USER}}|$user|g" \
    -e "s|{{GIT_REPO}}|$repo|g" \
    -e "s|{{LICENSE_ID}}|$license|g" \
    "$generator_config"
  rm -f "$generator_config.bak"

  # Fill in the git_ops repository URL (release automation)
  local config_exs="$PROJECT_ROOT/config/config.exs"
  if [[ -f "$config_exs" ]] && grep -q '{{GIT_REPO_URL}}' "$config_exs"; then
    sed -i.bak "s|{{GIT_REPO_URL}}|https://github.com/$user/$repo|g" "$config_exs"
    rm -f "$config_exs.bak"
    echo_info "Configured git_ops repository URL in config/config.exs"
  fi

  # Write base URL configuration into config/runtime.exs
  if [[ -n "$BASE_URL" ]]; then
    cat >> "$PROJECT_ROOT/config/runtime.exs" <<EOF

# Added by setup.sh
config :$PACKAGE_NAME,
  base_url: System.get_env("API_BASE_URL", "$BASE_URL")
EOF
    echo_info "Configured base URL in config/runtime.exs"
  fi

  echo_info "Configuration applied successfully."
}

# Fresh-initialize the release-facing docs for the new SDK. These files
# should describe the SDK from day one — not carry the template repository's
# own history. Skip with --keep-template-docs.
reset_sdk_docs() {
  if [[ "$KEEP_TEMPLATE_DOCS" == "1" ]]; then
    echo_warn "Keeping template README/CHANGELOG/docs (--keep-template-docs)"
    return 0
  fi

  echo_info "Fresh-initializing SDK docs (README, CHANGELOG, LICENSE)..."

  local year sdk_description base_url_line license_badge_text
  year=$(date +%Y)
  sdk_description="${DESCRIPTION:-Elixir client for the $GIT_REPO API}"

  if [[ -n "$BASE_URL" ]]; then
    base_url_line="  base_url: System.get_env(\"API_BASE_URL\", \"$BASE_URL\")"
  else
    base_url_line="  base_url: System.get_env(\"API_BASE_URL\")"
  fi

  # shields.io static badges use '-' as a separator and '_' as a space:
  # literal dashes/underscores in the label must be doubled
  # (Apache-2.0 -> Apache--2.0, my_pkg -> my__pkg)
  local pkg_badge_text
  license_badge_text=$(printf '%s' "$LICENSE_ID" | sed -e 's/-/--/g' -e 's/_/__/g' -e 's/ /%20/g')
  pkg_badge_text=$(printf '%s' "$PACKAGE_NAME" | sed -e 's/_/__/g')

  # CHANGELOG: fresh, with the git_ops marker used by release automation
  cat > "$PROJECT_ROOT/CHANGELOG.md" <<EOF
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are cut with \`mix git_ops.release\` (or the Release workflow), which
inserts new sections below this marker:

<!-- changelog -->

## [Unreleased]

### Added
- Initial SDK generated from the OpenAPI specification
EOF

  # README: minimal SDK README with real values. The YourSDK module
  # placeholder is replaced with the actual namespace by post-generate.sh
  # after the first generation.
  cat > "$PROJECT_ROOT/README.md" <<EOF
# $PACKAGE_NAME

[![Hex.pm](https://img.shields.io/hexpm/v/$PACKAGE_NAME.svg)](https://hex.pm/packages/$PACKAGE_NAME)
[![Documentation](https://img.shields.io/badge/hexdocs-$pkg_badge_text-blue.svg)](https://hexdocs.pm/$PACKAGE_NAME)
[![CI](https://github.com/$GIT_USER/$GIT_REPO/actions/workflows/test.yml/badge.svg)](https://github.com/$GIT_USER/$GIT_REPO/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-$license_badge_text-green.svg)](LICENSE)

$sdk_description

## Installation

Add \`$PACKAGE_NAME\` to your list of dependencies in \`mix.exs\`:

\`\`\`elixir
def deps do
  [
    {:$PACKAGE_NAME, "~> 0.1.0"}
  ]
end
\`\`\`

## Configuration

\`\`\`elixir
# config/runtime.exs
config :$PACKAGE_NAME,
$base_url_line
\`\`\`

## Usage

\`\`\`elixir
# Create a connection
conn = YourSDK.Connection.new()

# Make API calls — responses decode into typed model structs
{:ok, result} = YourSDK.Api.SomeApi.some_operation(conn, params)
\`\`\`

## Error handling

Operations return one of three shapes — note that \`{:ok, _}\` alone is **not**
a safe success match:

1. **Success statuses** decode into the mapped model struct.
2. **Error statuses declared in the OpenAPI spec** *also* return \`:ok\`,
   wrapping the spec's error model (an openapi-generator convention) — e.g. a
   400 comes back as \`{:ok, %YourSDK.Model.SomeErrorResponse{}}\`. Match on
   the struct, not just the tuple tag.
3. **Statuses the spec does not declare** (gateway 401/403s, proxy 502s, rate
   limits) return \`{:error, %Tesla.Env{status: status, body: body}}\`, with
   the body decoded to a map when the response is JSON.

Transport failures (connection refused, timeouts, DNS) surface as
\`{:error, reason}\` where \`reason\` comes from the configured Tesla adapter —
e.g. \`%Finch.TransportError{}\` with the default Finch adapter.

## Live smoke testing

The unit suite mocks the API from the spec, so it cannot catch places where
the spec and the real server disagree. A live smoke-test scaffold ships in
\`test/integration/live_test.exs\` (tagged \`:live\`, excluded by default):

\`\`\`bash
SDK_LIVE_BASE_URL=https://api.example.com SDK_LIVE_TOKEN=... mix test.live
\`\`\`

## Development

\`\`\`bash
./scripts/regenerate.sh   # regenerate from openapi-spec.yaml
mix check                 # full quality gate (mirrors CI)
mix dialyzer              # type check
\`\`\`

## Documentation

- [API Documentation](https://hexdocs.pm/$PACKAGE_NAME)
- [Changelog](CHANGELOG.md)

## License

See [LICENSE](LICENSE) for details.

---

**Generated with ❤️ using the [Elixir SDK Generator](https://github.com/houllette/elixir-sdk-generator) template**
EOF

  # LICENSE: fresh MIT with the SDK owner; other licenses need manual text
  if [[ "$LICENSE_ID" == "MIT" ]]; then
    cat > "$PROJECT_ROOT/LICENSE" <<EOF
MIT License

Copyright (c) $year $GIT_USER

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
  else
    echo_warn "LICENSE still contains the template's MIT text — replace it with $LICENSE_ID license text."
  fi

  # Template-only documentation
  rm -f "$PROJECT_ROOT/QUICKSTART.md"

  # CONTRIBUTING: written fresh for the SDK — the template's contributor
  # guide describes the template (wrong toolchain, free-form commits, a
  # manual release process that git_ops automates)
  cat > "$PROJECT_ROOT/CONTRIBUTING.md" <<EOF
# Contributing to $PACKAGE_NAME

Thanks for contributing! This SDK is **generated** from an OpenAPI
specification, which changes what a useful contribution looks like.

## Development setup

Tool versions are pinned in \`.tool-versions\` (asdf/mise). Then:

\`\`\`bash
mix deps.get
mix test
\`\`\`

## The golden rule: generated vs. persistent files

\`lib/\` and \`mix.exs\` are regenerated from the spec by
\`./scripts/regenerate.sh\` — **never hand-edit them**; your change will be
overwritten. Fixes belong in one of the persistent sources:

| To change… | Edit |
|---|---|
| The API surface | \`openapi-spec.yaml\` (or its upstream source) |
| A defect in the upstream spec | an idempotent patch in \`spec-patches/\` |
| How code is generated | \`.openapi-generator/templates/\` (complete vendored set — never delete files from it) |
| Post-generation behavior | \`scripts/post-generate.sh\` |
| Tests, config, docs, CI | \`test/\`, \`config/\`, \`*.md\`, \`.github/\` (all protected) |

After changing the spec or templates, run \`./scripts/regenerate.sh\` and
review the diff.

## Quality gate

Run the full gate before pushing — it mirrors CI:

\`\`\`bash
mix check      # unused deps, warnings-as-errors, format, credo --strict, tests
mix dialyzer   # type check (separate; slower)
\`\`\`

Coverage is enforced at the floor set in \`coveralls.json\`. The
reflection-driven surface tests in \`test/unit/\` cover the generated code
automatically; add behavior-specific tests (using the \`MockServer\` harness
in \`test/support/\`) for anything you touch.

## Commits and releases

- **Use Conventional Commit messages** (\`feat:\`, \`fix:\`, \`chore:\`,
  \`feat!:\` for breaking changes). PR titles are validated in CI; squash
  merges make them the commit history.
- Releases are automated from that history via git_ops: run the **Release**
  workflow (or \`mix git_ops.release\` locally — the very first release
  tags the current version manually instead; see the workflow docs). Never
  edit \`@version\` in mix.exs by hand.
- The committed SBOM (\`bom.cdx.json\`) is regenerated by the pre-commit
  hook when dependencies change — enable it with
  \`git config core.hooksPath .githooks\` if you cloned fresh.
EOF

  # Workflows README: written fresh for the SDK — the template's version
  # documents the .disabled naming scheme and setup-time enablement, which
  # are meaningless after minting
  cat > "$PROJECT_ROOT/.github/workflows/README.md" <<EOF
# GitHub Actions Workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| \`test.yml\` | push / PR | \`mix check\`-equivalent gate: tests + coverage floor (see \`coveralls.json\`), credo, dialyzer, minimum-toolchain compatibility, SBOM drift check |
| \`conventional-commits.yml\` | PR | Validates PR titles (Conventional Commits) — feeds release automation; use squash merges |
| \`release.yml\` | manual dispatch | git_ops release: version bump from commit history + changelog + tag, then triggers publish. First run tags the current version |
| \`publish.yml\` | \`v*.*.*\` tags | Publishes to Hex.pm and creates a GitHub release with the SBOM attached |
| \`spec-sync.yml\` | weekly + manual | Fetches the upstream spec URL from \`.spec-source\`, applies \`spec-patches/\`, opens a regeneration PR when it changed |
| \`regenerate-sdk.yml\` | spec changes on main | Opens a PR with the regenerated SDK |
| \`breaking-changes.yml\` | PRs touching spec/lib | oasdiff breaking-change gate + PR comment |

## Required secrets

- \`HEX_API_KEY\` — for publishing. Hex ≥ 2.5 removed
  \`mix hex.user key generate\`; create the key in the browser at
  hex.pm → Dashboard → Keys (permission \`api:write\`), then
  \`gh secret set HEX_API_KEY\`.

## Notes

- PRs created by workflows with the default \`GITHUB_TOKEN\` (spec-sync,
  regenerate-sdk) do **not** trigger other workflows. For CI on those PRs,
  store a fine-grained PAT as a secret and use it as the \`token\` input of
  the create-pull-request steps.
- release.yml never uses \`git_ops.release --initial\` (it conflicts with
  the existing CHANGELOG.md); the first release tags the current
  \`@version\` directly. Do the same when releasing locally.
EOF

  echo_info "SDK docs initialized (README, CHANGELOG, LICENSE, CONTRIBUTING, workflow docs; removed QUICKSTART.md)"
}

# Enable GitHub Actions workflows and remove template-only workflows
enable_workflows() {
  echo_info "Enabling GitHub Actions workflows..."

  local workflows_dir="$PROJECT_ROOT/.github/workflows"

  if [[ ! -d "$workflows_dir" ]]; then
    echo_warn "Workflows directory not found, skipping."
    return 0
  fi

  # The smoke-test workflow only makes sense for the template repository itself
  if [[ -f "$workflows_dir/template-smoke.yml" ]]; then
    rm -f "$workflows_dir/template-smoke.yml"
    echo_info "Removed template-only workflow: template-smoke.yml"
  fi

  local enabled_count=0

  for disabled_file in "$workflows_dir"/*.disabled; do
    if [[ -f "$disabled_file" ]]; then
      local enabled_file="${disabled_file%.disabled}"
      mv "$disabled_file" "$enabled_file"
      echo_info "Enabled: $(basename "$enabled_file")"
      enabled_count=$((enabled_count + 1))
    fi
  done

  if [[ $enabled_count -eq 0 ]]; then
    echo_info "No disabled workflows found (may already be enabled)"
  else
    echo_info "Enabled $enabled_count workflow(s)"
  fi
}

# Remove template-only artifacts that make no sense in a configured SDK repo.
# The /setup-sdk skill is one-shot by design: once the SDK exists, only the
# /regenerate skill remains relevant, so setup cleans it up here (this also
# covers the case where the skill itself invoked this script).
cleanup_template_artifacts() {
  local setup_skill_dir="$PROJECT_ROOT/.claude/skills/setup-sdk"

  if [[ -d "$setup_skill_dir" ]]; then
    rm -rf "$setup_skill_dir"
    echo_info "Removed template-only skill: /setup-sdk (the /regenerate skill remains)"
  fi

  # A bom.cdx.json inherited from the template describes the template's
  # project, not this SDK — the first regeneration writes a fresh one.
  if [[ -f "$PROJECT_ROOT/bom.cdx.json" ]]; then
    rm -f "$PROJECT_ROOT/bom.cdx.json"
    echo_info "Removed stale template SBOM (regenerated on first ./scripts/regenerate.sh)"
  fi
}

# Substitute the real package name into the commented configuration examples
# so config/*.exs never contradicts the appended real configuration.
personalize_config_examples() {
  local f
  for f in "$PROJECT_ROOT"/config/dev.exs "$PROJECT_ROOT"/config/test.exs "$PROJECT_ROOT"/config/runtime.exs; do
    if [[ -f "$f" ]] && grep -q 'your_package_name' "$f"; then
      sed -i.bak "s/your_package_name/$PACKAGE_NAME/g" "$f"
      rm -f "$f.bak"
    fi
  done
  echo_info "Personalized configuration examples in config/*.exs"
}

# Setup is one-shot: once the placeholders are replaced it permanently
# refuses to run again, so leaving its machinery and tombstone comments
# behind only confuses contributors. Remove them — this runs LAST, and the
# script deleting itself is safe because bash has already parsed it.
remove_setup_machinery() {
  # Strip the setup section from CONTRIBUTING.md (everything from the
  # "### Setup Script" heading up to, but not including, the next heading)
  if [[ -f "$PROJECT_ROOT/CONTRIBUTING.md" ]] && grep -q '^### Setup Script' "$PROJECT_ROOT/CONTRIBUTING.md"; then
    sed -i.bak '/^### Setup Script$/,/^### Regenerate Script$/{/^### Regenerate Script$/!d;}' "$PROJECT_ROOT/CONTRIBUTING.md"
    rm -f "$PROJECT_ROOT/CONTRIBUTING.md.bak"
  fi

  # Remove "(will be replaced by setup.sh)"-style tombstones
  sed -i.bak \
    -e 's/ (will be replaced by setup\.sh)//g' \
    -e 's/ (will be replaced by setup\.sh;/ (defaults:/g' \
    -e 's/The lib\/ path is filled in by scripts\/setup\.sh (underscored module name)\./The lib\/ path follows the underscored module namespace./g' \
    "$PROJECT_ROOT/generator-config.yaml"
  rm -f "$PROJECT_ROOT/generator-config.yaml.bak"

  # Remove the post-setup placeholder comment from AGENTS.md
  if [[ -f "$PROJECT_ROOT/AGENTS.md" ]]; then
    sed -i.bak '/^<!-- After setup:/,/-->$/d' "$PROJECT_ROOT/AGENTS.md"
    rm -f "$PROJECT_ROOT/AGENTS.md.bak"
  fi

  # Remove the setup config example and its protection entry
  rm -f "$PROJECT_ROOT/setup.example.json"
  sed -i.bak '/^setup\.example\.json$/d' "$PROJECT_ROOT/.openapi-generator-ignore"
  rm -f "$PROJECT_ROOT/.openapi-generator-ignore.bak"

  # Finally, remove this script
  rm -f "$SCRIPT_DIR/setup.sh"
  echo_info "Removed one-shot setup machinery (setup.sh, setup.example.json, tombstone comments)"
}

# Point git at the versioned hooks directory (pre-commit keeps the SBOM in
# sync with dependency changes)
configure_git_hooks() {
  if [[ -d "$PROJECT_ROOT/.git" ]] && [[ -d "$PROJECT_ROOT/.githooks" ]]; then
    git -C "$PROJECT_ROOT" config core.hooksPath .githooks
    echo_info "Configured git hooks path (.githooks — pre-commit keeps bom.cdx.json in sync)"
  fi
}

# Initialize git if not already a repo
init_git() {
  if [[ "$SKIP_GIT" == "1" ]]; then
    echo_info "Skipping git initialization (--no-git)"
    return 0
  fi

  if [[ ! -d "$PROJECT_ROOT/.git" ]]; then
    echo_info "Initializing git repository..."
    cd "$PROJECT_ROOT"
    git init
    git add .
    git commit -m "Initial commit from elixir-sdk-generator template"

    if [[ -n "$GIT_USER" ]] && [[ -n "$GIT_REPO" ]]; then
      echo_info "Setting up git remote..."
      git remote add origin "git@github.com:${GIT_USER}/${GIT_REPO}.git"
      echo_info "Remote 'origin' set to: git@github.com:${GIT_USER}/${GIT_REPO}.git"
    fi
  else
    echo_info "Git repository already initialized."
  fi
}

# Main execution
main() {
  check_dependencies
  check_not_already_configured

  if [[ -n "$CONFIG_FILE" ]]; then
    read_config_file
  else
    prompt_config
  fi

  validate_config
  apply_config
  personalize_config_examples
  reset_sdk_docs
  enable_workflows
  cleanup_template_artifacts
  # Must run before init_git so a fresh repo's initial commit doesn't
  # include the one-shot setup machinery
  remove_setup_machinery
  init_git
  configure_git_hooks

  echo ""
  echo_info "Setup complete! Next steps:"
  echo ""
  echo "  1. Review the configuration in generator-config.yaml"
  echo "  2. Run: ./scripts/regenerate.sh"
  echo "  3. Run tests: mix test"
  echo "  4. Review the generated SDK in lib/"
  echo ""
  echo_info "To regenerate the SDK after updating the OpenAPI spec:"
  echo "  ./scripts/regenerate.sh"
  echo ""
}

main
