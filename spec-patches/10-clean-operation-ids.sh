#!/usr/bin/env bash
set -euo pipefail

# 10-clean-operation-ids.sh — durable fixes for upstream operationId defects.
#
# 1. The analytics spec's organization-scoped paths ship without operationIds,
#    so the generator derives function names from the full path — e.g.
#    `organization_organization_id_usage_aggregated_get/4`. Add clean,
#    camelCase operationIds (the generator snake_cases them) matching the
#    naming style of the analytics endpoints that DO have ids
#    (`getSandboxLogs`, `getOrganizationUsageOverview`).
#    Only fills MISSING ids: if upstream ever adds their own, theirs win and
#    the change shows up in the spec-sync PR diff.
#
# 2. The main spec leaks NestJS controller class names into some
#    operationIds (`ConfigController_getConfig`, `WebhookController_send`),
#    yielding functions like `config_controller_get_config/1`. Strip the
#    `<Name>Controller_` prefix.
#
# Idempotent: filling an already-present id is a no-op, and stripped
# prefixes cannot be stripped twice. Output stays jq -S formatted, matching
# scripts/fetch-spec.sh, so spec-sync byte comparisons remain stable.
#
# jq is already a hard prerequisite of scripts/fetch-spec.sh, so using it
# here adds no new dependency.

SPEC="$1"

if ! command -v jq &> /dev/null; then
  echo "jq is required" >&2
  exit 1
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

jq -S '
  # --- 1. Fill missing analytics operationIds --------------------------------
  reduce (
    [
      ["/organization/{organizationId}/sandbox/{sandboxId}/telemetry/logs",             "get", "getOrganizationSandboxLogs"],
      ["/organization/{organizationId}/sandbox/{sandboxId}/telemetry/metrics",          "get", "getOrganizationSandboxMetrics"],
      ["/organization/{organizationId}/sandbox/{sandboxId}/telemetry/traces",           "get", "getOrganizationSandboxTraces"],
      ["/organization/{organizationId}/sandbox/{sandboxId}/telemetry/traces/{traceId}", "get", "getOrganizationSandboxTraceSpans"],
      ["/organization/{organizationId}/sandbox/{sandboxId}/usage",                      "get", "getOrganizationSandboxUsage"],
      ["/organization/{organizationId}/usage/aggregated",                               "get", "getOrganizationUsageAggregated"],
      ["/organization/{organizationId}/usage/chart",                                    "get", "getOrganizationUsageChart"],
      ["/organization/{organizationId}/usage/sandbox",                                  "get", "getOrganizationUsagePerSandbox"]
    ][]
  ) as [$path, $method, $id] (
    .;
    if (.paths[$path][$method] // null) != null
       and (.paths[$path][$method].operationId // null) == null
    then .paths[$path][$method].operationId = $id
    else .
    end
  )
  # --- 2. Strip NestJS controller-class prefixes -----------------------------
  | .paths |= map_values(map_values(
      if type == "object" and has("operationId")
      then .operationId |= sub("^[A-Za-z]+Controller_"; "")
      else .
      end
    ))
' "$SPEC" > "$TMP"

mv "$TMP" "$SPEC"
