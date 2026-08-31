#!/usr/bin/env bash
set -euo pipefail

# Applies local patches to the OpenAPI spec (see spec-patches/README.md).
#
# Real-world upstream specs ship defects — duplicate operationIds, parameters
# declared in two places, invalid enum values. Patching openapi-spec.yaml in
# place is not durable: the spec-sync workflow re-downloads the upstream spec
# and would silently reintroduce every defect. Patches in spec-patches/ are
# applied automatically after every download (setup, spec-sync) and before
# every regeneration, so local fixes survive spec updates and stay reviewable.
#
# Usage: apply-spec-patches.sh [SPEC_PATH]   (default: openapi-spec.yaml)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SPEC="${1:-$PROJECT_ROOT/openapi-spec.yaml}"
PATCH_DIR="$PROJECT_ROOT/spec-patches"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo_info() { echo -e "${GREEN}[SPEC-PATCH]${NC} $*"; }
echo_error() { echo -e "${RED}[SPEC-PATCH]${NC} $*"; }

if [[ ! -d "$PATCH_DIR" ]]; then
  exit 0
fi

applied=0

for patch in "$PATCH_DIR"/*; do
  # Only executable files are patches (README.md etc. are documentation)
  if [[ ! -f "$patch" ]] || [[ ! -x "$patch" ]]; then
    continue
  fi

  if "$patch" "$SPEC"; then
    echo_info "Applied $(basename "$patch")"
    applied=$((applied + 1))
  else
    echo_error "Spec patch failed: $(basename "$patch")"
    echo_error "The upstream spec may have changed shape — or fixed the defect this"
    echo_error "patch works around, in which case the patch should be deleted."
    exit 1
  fi
done

if [[ $applied -gt 0 ]]; then
  echo_info "Applied $applied spec patch(es) to $SPEC"
fi
