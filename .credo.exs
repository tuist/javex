%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "mix.exs"],
        excluded: []
      },
      strict: true,
      color: true
    }
  ]
}
