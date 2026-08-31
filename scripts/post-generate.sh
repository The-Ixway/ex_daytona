#!/usr/bin/env bash
set -euo pipefail

# Post-generation processing script
# Runs after OpenAPI Generator completes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() { echo -e "${GREEN}[POST-GEN]${NC} $*"; }
echo_warn() { echo -e "${YELLOW}[POST-GEN]${NC} $*"; }

# Fix common issues in generated code
fix_generated_code() {
  echo_info "Fixing common issues in generated code..."

  # Remove any accidentally generated files in protected directories
  if [[ -d "$PROJECT_ROOT/test" ]]; then
    # Remove auto-generated test files that might conflict with our custom tests
    find "$PROJECT_ROOT/test" -name "*_test.exs" -type f -exec grep -l "AUTO-GENERATED" {} \; | while read -r file; do
      echo_warn "Removing auto-generated test file: $file"
      rm -f "$file"
    done
  fi

  echo_info "Code fixes applied."
}

# Detect the installed OpenAPI Generator version
generator_version() {
  if command -v openapi-generator &> /dev/null; then
    openapi-generator version 2>/dev/null || echo "unknown"
  elif command -v npx &> /dev/null; then
    npx @openapitools/openapi-generator-cli version 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

# Update .openapi-generator/VERSION file
update_version_file() {
  local version_file="$PROJECT_ROOT/.openapi-generator/VERSION"
  local version_dir
  version_dir=$(dirname "$version_file")

  mkdir -p "$version_dir"

  # Record the generator version and timestamp
  {
    echo "Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "OpenAPI Generator version: $(generator_version)"
    echo "Spec file: openapi-spec.yaml"
  } > "$version_file"

  echo_info "Updated version file."
}

# Ensure test directories exist
ensure_test_structure() {
  echo_info "Ensuring test directory structure..."

  mkdir -p "$PROJECT_ROOT/test/unit"
  mkdir -p "$PROJECT_ROOT/test/integration"
  mkdir -p "$PROJECT_ROOT/test/support"
  mkdir -p "$PROJECT_ROOT/test/fixtures"

  echo_info "Test structure verified."
}

# Report the module name the generator derived, so users know what to alias.
# Also fills the YourSDK placeholder that setup.sh leaves in the README (the
# real namespace is only known after the first generation).
report_module_name() {
  local connection_file
  connection_file=$(find "$PROJECT_ROOT/lib" -name "connection.ex" 2>/dev/null | head -1)

  if [[ -n "$connection_file" ]]; then
    local module_base
    module_base=$(grep -m1 "^defmodule " "$connection_file" | sed -E 's/defmodule ([A-Za-z0-9_.]+)\.Connection do/\1/')
    if [[ -n "$module_base" ]]; then
      echo_info "Generated SDK module namespace: $module_base"

      if [[ -f "$PROJECT_ROOT/README.md" ]] && grep -q "YourSDK" "$PROJECT_ROOT/README.md"; then
        sed -i.bak "s/YourSDK/$module_base/g" "$PROJECT_ROOT/README.md"
        rm -f "$PROJECT_ROOT/README.md.bak"
        echo_info "Filled SDK module namespace into README.md"
      fi
    fi
  fi
}

# Generate a simple test template for new APIs
generate_test_templates() {
  echo_info "Checking for new API modules without tests..."

  local api_dir
  api_dir=$(find "$PROJECT_ROOT/lib" -type d -name "api" 2>/dev/null | head -1)
  local test_unit_dir="$PROJECT_ROOT/test/unit"

  if [[ -z "$api_dir" ]]; then
    return 0
  fi

  find "$api_dir" -type f -name "*.ex" | while read -r api_file; do
    local basename
    basename=$(basename "$api_file" .ex)
    local test_file="$test_unit_dir/${basename}_api_test.exs"

    # Skip if test already exists
    if [[ -f "$test_file" ]]; then
      continue
    fi

    # Extract module name from file (e.g. MySDK.Api.Users)
    local module_name
    module_name=$(grep -m1 "^defmodule " "$api_file" | sed -E 's/defmodule ([A-Za-z0-9_.]+) do/\1/')

    if [[ -z "$module_name" ]]; then
      continue
    fi

    echo_info "Creating test template for $module_name"

    cat > "$test_file" <<EOF
defmodule ${module_name}Test do
  use TestCase, async: true

  alias ${module_name}
  alias ${module_name%%.*}.Connection

  setup do
    bypass = MockServer.setup()
    conn = Connection.new(base_url: MockServer.url(bypass))
    {:ok, bypass: bypass, conn: conn}
  end

  # Add tests for each operation in ${module_name}, for example:
  #
  #   test "lists things", %{bypass: bypass, conn: conn} do
  #     MockServer.expect_get(bypass, "/things", 200, %{things: []})
  #     assert {:ok, _response} = ${module_name##*.}.list_things(conn)
  #   end

  test "module is generated and loaded" do
    assert Code.ensure_loaded?(${module_name##*.})
  end
end
EOF

  done
}

# Main execution
main() {
  echo_info "Running post-generation processing..."

  fix_generated_code
  update_version_file
  ensure_test_structure
  report_module_name
  generate_test_templates

  echo_info "Post-generation processing complete."
}

main
