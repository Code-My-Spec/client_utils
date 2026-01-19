defmodule ClientUtils.MixProject do
  use Mix.Project

  def project do
    [
      app: :client_utils,
      version: "0.1.1",
      elixir: "~> 1.18",
      description: "ExUnit formatter with JSON output and distributed test coordination",
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_paths: ["test"],
      test_pattern: "*_test.exs"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["John Davenport"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/Code-My-Spec/client_utils"}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
