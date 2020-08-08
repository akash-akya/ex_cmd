defmodule ExCmd.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_cmd,
      version: "0.4.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Package
      package: package(),
      description: description(),

      # Docs
      source_url: "https://github.com/akash-akya/ex_cmd",
      homepage_url: "https://github.com/akash-akya/ex_cmd",
      docs: [
        main: "readme",
        extras: ["README.md"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Interact with external programs with back-pressure"
  end

  defp package do
    [
      maintainers: ["Akash Hiremath"],
      licenses: ["MIT"],
      links: %{GitHub: "https://github.com/akash-akya/ex_cmd"}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:gen_state_machine, "~> 2.0"},
      {:ex_doc, ">= 0.0.0", only: :dev}
    ]
  end
end
