#!/usr/bin/env elixir
# Verifies that a freshly generated SBOM matches the committed one.
#
# Usage: elixir scripts/verify_sbom.exs COMMITTED_BOM FRESH_BOM
#
# Only fields deterministically derived from mix.exs/mix.lock are compared
# (root component + pkg:hex components + the dependency graph pruned to kept
# refs): `mix sbom` enriches metadata from the hex.pm API (network-dependent)
# and OTP system components carry the versions of whichever Erlang build
# generated the bom, so neither can compare stably between machines. Prints
# a unified diff of the normalized forms on mismatch and exits non-zero.

defmodule VerifySbom do
  @keep ~w(bom-ref type name version purl scope hashes)

  def normalize(path) do
    bom = JSON.decode!(File.read!(path))

    root = prune(get_in(bom, ["metadata", "component"]) || %{})

    components =
      bom
      |> Map.get("components", [])
      |> Enum.filter(&String.starts_with?(Map.get(&1, "purl") || "", "pkg:hex/"))
      |> Enum.map(&prune/1)
      |> Enum.sort_by(&{Map.get(&1, "purl") || Map.get(&1, "name", ""), Map.get(&1, "version", "")})

    kept_refs =
      components
      |> Enum.map(&Map.get(&1, "bom-ref"))
      |> MapSet.new()
      |> MapSet.put(Map.get(root, "bom-ref"))

    dependencies =
      bom
      |> Map.get("dependencies", [])
      |> Enum.filter(&MapSet.member?(kept_refs, Map.get(&1, "ref")))
      |> Enum.map(fn dep ->
        %{
          "ref" => Map.get(dep, "ref"),
          "dependsOn" =>
            dep |> Map.get("dependsOn", []) |> Enum.filter(&MapSet.member?(kept_refs, &1)) |> Enum.sort()
        }
      end)
      |> Enum.sort_by(&Map.get(&1, "ref"))

    %{root: root, components: components, dependencies: dependencies}
  end

  defp prune(component), do: Map.take(component, @keep)

  # `inspect` prints map keys in deterministic sorted term order, giving a
  # stable, readable representation for diffing.
  def dump(term), do: inspect(term, pretty: true, limit: :infinity, width: 98) <> "\n"
end

[committed_path, fresh_path] = System.argv()

committed = VerifySbom.normalize(committed_path)
fresh = VerifySbom.normalize(fresh_path)

if committed == fresh do
  IO.puts("SBOM is up to date.")
else
  tmp = System.tmp_dir!()
  committed_dump = Path.join(tmp, "sbom-committed-normalized.txt")
  fresh_dump = Path.join(tmp, "sbom-fresh-normalized.txt")
  File.write!(committed_dump, VerifySbom.dump(committed))
  File.write!(fresh_dump, VerifySbom.dump(fresh))

  {diff, _status} =
    System.cmd("diff", ["-u", "--label", "committed bom.cdx.json", "--label", "freshly generated bom.cdx.json", committed_dump, fresh_dump])

  IO.puts(diff)
  IO.puts("::error::bom.cdx.json is out of date. Run 'mix sbom' and commit the result")
  IO.puts("::error::(or enable the versioned hooks: git config core.hooksPath .githooks).")
  System.halt(1)
end
