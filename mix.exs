defmodule ClientUtils.MixProject do
  use Mix.Project

  @source_url "https://github.com/Code-My-Spec/client_utils"

  def project do
    [
      app: :client_utils,
      version: "0.1.38",
      elixir: "~> 1.18",
      description: "ExUnit formatter with JSON output and distributed test coordination",
      package: package(),
      docs: docs(),
      source_url: @source_url,
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
      files: ["lib", "priv", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["John Davenport"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.0"},
      # Onboarding asks the server for this copy's preview address. Creating the
      # tunnel behind it needs a Cloudflare credential that must never ship in a
      # generated application, so the server does that and this asks.
      #
      # Free for the applications that consume this: `phx.new` has put
      # `{:req, "~> 0.5"}` in every generated mix.exs since 1.7, so it is already
      # resolved wherever this runs.
      {:req, "~> 0.5"},
      # For `ClientUtils.PreviewFraming`. Optional because a consumer that is not
      # a web application has no use for it and should not be made to resolve
      # it; every Phoenix app already has it, which is every app that could want
      # the plug.
      {:plug, "~> 1.0", optional: true},
      {:logger_file_backend, "~> 0.0.14"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
