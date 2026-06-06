%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      checks: [
        {Credo.Check.Design.TagFIXME},
        {Credo.Check.Design.TagTODO},
        {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 15},
        {Credo.Check.Refactor.NegatedConditionsInIfElseBlocks, false},
        {Credo.Check.Refactor.NegatedConditionsWithElse, false}
      ]
    }
  ]
}
