[
  plugins: [Quokka],
  inputs: ["{mix,.formatter,.credo}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  quokka: [
    files: %{
      excluded: ["lib/javex/native.ex"]
    }
  ]
]
