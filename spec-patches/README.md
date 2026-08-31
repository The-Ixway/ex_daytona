# Spec patches

Durable local fixes for defects in the upstream OpenAPI spec.

Real-world specs ship problems — duplicate `operationId`s, a parameter
declared in both query and body, invalid examples. Editing
`openapi-spec.yaml` by hand is not durable: the weekly spec-sync workflow
re-downloads the upstream spec and silently reintroduces every defect.
Patches placed here are applied automatically:

- after the spec is downloaded (setup and the spec-sync workflow), and
- before every regeneration (`./scripts/regenerate.sh`),

so your fixes survive spec updates and stay reviewable in git.

## Contract

- A patch is any **executable** file in this directory (non-executable files
  like this README are ignored). An `.exs` file with an
  `#!/usr/bin/env elixir` shebang works directly — Elixir is the one
  scripting runtime guaranteed on every machine that builds this SDK, so
  prefer it (or POSIX sed/awk) over tools that add prerequisites.
- Patches run in **lexicographic order** — prefix them with a number:
  `10-dedupe-operation-ids.exs`, `20-drop-duplicate-param.exs`.
- Each patch is invoked with one argument: the path to the spec file, and
  should edit the file in place.
- Patches **must be idempotent**: they run on every regeneration, including
  on a spec they already patched.
- A patch that exits non-zero **fails the pipeline** with a clear message.
  If upstream fixed the defect a patch works around, delete the patch.

## Example

```elixir
#!/usr/bin/env elixir
# 10-rename-duplicate-operation-id.exs — upstream declares listItems twice
[spec_path] = System.argv()

spec = File.read!(spec_path)

# Idempotent: String.replace is a no-op once the rename has been applied.
patched =
  String.replace(
    spec,
    ~s("operationId": "listItems",\n        "tags": ["archive"]),
    ~s("operationId": "listArchivedItems",\n        "tags": ["archive"])
  )

File.write!(spec_path, patched)
```

For structural edits to JSON specs, decode with the built-in `JSON` module,
transform, and re-encode deterministically (sort object keys so repeated
runs are byte-stable — spec-sync compares the patched download to the
committed spec byte-for-byte).

Spec-sync PRs will fail loudly (rather than silently regressing) when a
patch no longer applies cleanly.
