defmodule ExCmd.MixProject do
  use Mix.Project

  @version "0.12.0"
  @scm_url "https://github.com/akash-akya/ex_cmd"

  def project do
    [
      app: :ex_cmd,
      version: @version,
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: Mix.compilers() ++ [:odu],
      aliases: aliases(),

      # Ensure dialyzer sees mix modules
      dialyzer: [plt_add_apps: [:mix]],

      # Package
      package: package(),
      description: description(),

      # Docs
      source_url: @scm_url,
      homepage_url: @scm_url,
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: [
          "README.md",
          "LICENSE"
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Interact with external programs with back-pressure mechanism"
  end

  defp package do
    [
      maintainers: ["Akash Hiremath"],
      licenses: ["MIT"],
      files: ~w(lib priv .formatter.exs mix.exs README* LICENSE* go_src),
      links: %{GitHub: @scm_url}
    ]
  end

  defp aliases do
    [
      format: [
        "format",
        "cmd --cd go_src/ go fmt"
      ]
    ]
  end

  defp deps do
    [
      # development & test
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev}
    ]
  end
end
