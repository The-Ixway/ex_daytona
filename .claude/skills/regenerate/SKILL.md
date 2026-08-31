---
name: regenerate
description: Regenerate this SDK from its OpenAPI spec and review the result. Optionally refreshes the spec from its recorded source URL first, runs scripts/regenerate.sh, summarizes the API diff, updates tests for new endpoints, and updates the CHANGELOG. Use after the spec changed, after editing templates, or when the user asks to sync with the upstream API.
argument-hint: "[--refresh-spec]"
---

# Regenerate the SDK

## 1. Preflight

- If `generator-config.yaml` still contains `{{PACKAGE_NAME}}`, stop: the
  project isn't configured yet. Suggest `/setup-sdk`.
- Make sure the working tree is clean enough to review a diff (`git status`);
  if there are unrelated uncommitted changes, ask the user before mixing
  regeneration output into them.

## 2. Optionally refresh the spec

If the user passed `--refresh-spec` or asked to sync with upstream:

- Read the source URL from `.spec-source`. If it doesn't exist, ask the user
  for the URL (and offer to record it in `.spec-source` for the weekly
  spec-sync workflow).
- Download it over `openapi-spec.yaml` (convert GitHub `/blob/` URLs to
  `raw.githubusercontent.com`). If `git diff openapi-spec.yaml` is empty,
  tell the user the spec is already up to date and stop unless they want to
  regenerate anyway (e.g. after template changes).

## 3. Regenerate

Run `./scripts/regenerate.sh`. It validates the spec, backs up `lib/`,
generates, post-processes (starter tests for new API modules), installs
deps, formats, and runs the tests.

## 4. Review the result

1. Summarize `git diff --stat` and call out: new/removed API modules, new or
   changed operations, and model changes.
2. Check for breaking changes: removed public functions or changed
   signatures in `lib/**/api/`. Flag them clearly — they require a major
   version bump.
3. Run `mix test`. If tests fail because the API changed, update the
   affected tests in `test/` (never patch generated code in `lib/` — see
   AGENTS.md).
4. Flesh out any newly created starter tests in `test/unit/` with at least
   one real request/response test per new operation, using `MockServer`.
5. If dependencies changed, confirm `bom.cdx.json` was regenerated (the
   regenerate script and pre-commit hook both do this; `mix sbom` refreshes
   it manually).

## 5. Finish

- Add a CHANGELOG.md entry under `[Unreleased]` describing the API changes
  (and "Breaking:" markers where relevant).
- Report: what changed, test results, and whether a version bump is needed
  (breaking → major, new endpoints → minor, fixes → patch). Versioning is
  automated: commit with a conventional message (`feat:`/`fix:`/`feat!:`)
  and cut the release later with `mix git_ops.release` or the Release
  workflow — don't edit `@version` by hand.
- Offer to commit — do not commit unless the user agrees.
