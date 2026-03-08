%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "config/", "test/", "mix.exs"],
        excluded: []
      },
      strict: true,
      color: true,
      checks: %{
        extra: [
          {Credo.Check.Design.TagTODO, [exit_status: 0]}
        ]
      }
    }
  ]
}
