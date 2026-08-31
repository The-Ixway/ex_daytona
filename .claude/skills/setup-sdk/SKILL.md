---
name: setup-sdk
description: Use the Elixir SDK Generator template to mint a real SDK. Asks about the API being wrapped, runs scripts/setup.sh (which fresh-initializes README/CHANGELOG/LICENSE for the SDK) and the first generation, then updates the docs. One-shot by design — setup removes this skill afterwards (the /regenerate skill remains for the SDK's lifetime). Use when generator-config.yaml still contains {{PACKAGE_NAME}} placeholders and the user wants to start their SDK.
argument-hint: "[optional package name]"
---

# Mint an SDK from this template

Turn this template repo into a configured, generated Elixir SDK. This skill
is **one-shot**: `scripts/setup.sh` deletes `.claude/skills/setup-sdk/` as
part of setup, so a minted SDK repo keeps only the `/regenerate` maintenance
skill. Don't be surprised when this file disappears mid-run — that is
intended behavior, not an error.

## 1. Preflight

- If `generator-config.yaml` does **not** contain `{{PACKAGE_NAME}}`, stop:
  the project is already configured. Suggest `/regenerate` instead.
- Confirm the toolchain: `mix --version` (versions pinned in
  `.tool-versions`), `jq`, and one of `openapi-generator` / `npx` / `docker`
  for OpenAPI Generator. If something is missing, tell the user how to
  install it and stop.

## 2. Ask what they're building

Use AskUserQuestion (skip the package-name question if a name was passed as
the skill argument):

1. **Package name** — hex package name, must match `^[a-z][a-z0-9_]*$`.
   Offer the repo directory name converted to snake_case as the recommended
   option.
2. **OpenAPI spec source** — options: "URL (recommended — enables the weekly
   spec-sync workflow; GitHub blob URLs are converted to raw automatically)",
   "Local file path", "Keep the bundled example spec for now".
3. **Module namespace** — "Derive from package name (recommended)" or a
   custom PascalCase name (validate `^[A-Z][A-Za-z0-9]*$`).

Setup fresh-initializes README, CHANGELOG, and LICENSE for the new SDK and
removes template-only docs automatically (pass `--keep-template-docs` only if
the user explicitly wants to keep them).

Collect as free text (ask in one round, "Other" allows custom input):
GitHub `owner/repo`, an optional one-line description, an optional API base
URL, and the license SPDX id (default MIT).

## 3. Run setup and first generation

1. Write the answers to a JSON file in the scratchpad directory using the
   `setup.example.json` key format (`package_name`, `module_name`,
   `description`, `git_user`, `git_repo`, `base_url`, `openapi_spec_path`,
   `license`).
2. Run `./scripts/setup.sh --config <file>` (add `--no-git` only if the repo
   is already a git repo — it is when cloned from the template, so setup will
   detect that itself). Setup fresh-initializes the SDK docs, enables the CI
   workflows, removes the template-only smoke-test workflow, and **removes
   this skill**.
3. Run `./scripts/regenerate.sh`. If it fails, diagnose from the output —
   spec validation errors mean the spec needs fixing, template errors mean
   `.openapi-generator/templates/` was modified incorrectly.
4. Verify: `mix check` (compile, format, credo, tests).

## 4. Update the docs

- `AGENTS.md`: delete the "About this repo" template paragraph; fill in
  "Project overview" with the API name, module namespace, and spec source.
- `README.md`: setup wrote a fresh SDK README and the first generation filled
  in the real module namespace — review it and enrich the usage example with
  a real operation from the generated API modules.

## 5. Finish

- Confirm the self-cleanup happened: `.claude/skills/setup-sdk/` should no
  longer exist (remove it yourself if setup was interrupted after
  generation succeeded) and `.claude/skills/regenerate/` should remain.
- Summarize: package/module names, spec source (and whether `.spec-source`
  was recorded for weekly spec-sync), test results, which workflows were
  enabled, and that this skill removed itself — future maintenance goes
  through `/regenerate`.
- Offer to commit — do not commit unless the user agrees.
