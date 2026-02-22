defmodule JidoMcp.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_mcp"

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
      description: "MCP integration package for the Jido ecosystem",
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
      {:jido, path: "../jido"},
      {:anubis_mcp, path: "../anubis-mcp"},
      {:jason, "~> 1.4"},
      {:zoi, "~> 0.17"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:mimic, "~> 2.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: "test"
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end
end
