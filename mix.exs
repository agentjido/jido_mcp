defmodule JidoMcp.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/agentjido/jido_mcp"
  @description "MCP integration package for the Jido ecosystem"

  def project do
    [
      app: :jido_mcp,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Documentation
      name: "Jido MCP",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Jido.MCP.Application, []}
    ]
  end

  defp deps do
    [
      {:jido, "~> 2.0"},
      {:anubis_mcp, "~> 0.17.0"},
      {:jason, "~> 1.4"},
      {:zoi, "~> 0.17"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:mimic, "~> 2.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: "test",
      "release.check": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "cmd env MIX_ENV=test mix test",
        "cmd mix hex.build"
      ]
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "CHANGELOG.md", "LICENSE"],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Documentation" => "https://hexdocs.pm/jido_mcp",
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md", "LICENSE"]
    ]
  end
end
