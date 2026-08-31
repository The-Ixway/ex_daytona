%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      checks: %{
        extra: [
          # lib/ is fully generated from the OpenAPI spec. These limits are
          # violated by spec-driven names and schemas (long inline-schema
          # module names, large upstream structs, operationIds like
          # isAuthEnabled), so they only apply to hand-written code.
          {Credo.Check.Readability.MaxLineLength, files: %{excluded: ["lib/"]}},
          {Credo.Check.Readability.PredicateFunctionNames, files: %{excluded: ["lib/"]}},
          {Credo.Check.Warning.StructFieldAmount, files: %{excluded: ["lib/"]}}
        ]
      }
    }
  ]
}
