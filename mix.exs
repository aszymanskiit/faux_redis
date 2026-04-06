defmodule FauxRedis.MixProject do
  use Mix.Project

  @source_url "https://github.com/aszymanskiit/faux_redis"
  @version "1.0.1"

  def project do
    [
      app: :faux_redis,
      version: @version,
      elixir: "~> 1.13",
      required_otp_version: ">= 24.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      elixirc_paths: elixirc_paths(Mix.env()),
      source_url: @source_url,
      docs: docs(),
      package: package(),
      description:
        "Controllable fake Redis server for integration testing (ejabberd/XMPP-friendly)",
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.lcov": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {FauxRedis.Application, []}
    ]
  end

  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_add_deps: false,
      plt_add_apps: [:ex_unit],
      ignore_warnings: "dialyzer.ignore-warnings"
    ]
  end

  defp docs do
    [
      main: "FauxRedis",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        API: [FauxRedis, FauxRedis.Case],
        Implementation: [
          FauxRedis.Application,
          FauxRedis.Command,
          FauxRedis.Connection,
          FauxRedis.MockEngine,
          FauxRedis.MockRule,
          FauxRedis.RESP,
          FauxRedis.Server,
          FauxRedis.Store
        ]
      ]
    ]
  end

  defp package do
    [
      maintainers: ["aszymanskiit"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib config mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end
end
