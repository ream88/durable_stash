defmodule DurableStash.MixProject do
  use Mix.Project

  @source_url "https://github.com/ream88/durable_stash"

  def project do
    [
      app: :durable_stash,
      version: "0.1.2",
      description: "Keep LiveView state alive across reconnects, crashes, and redeploys",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      # :os_mon is only needed when DurableServer capacity limits
      # (max_cpu/max_memory/max_disk) are configured — hosts that use them
      # must add :os_mon to their own extra_applications (see durable_server docs).
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:durable_server, "~> 0.1.4"},
      {:live_stash, "~> 1.0"},
      # TODO: drop override once req_s3 supports req 0.6 (pinned to ~> 0.5.6; override needed for CVE-2026-49755)
      {:req, "~> 0.6", override: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:styler, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md .formatter.exs),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "LiveStash" => "https://github.com/software-mansion-labs/live-stash",
        "DurableServer" => "https://github.com/phoenixframework/durable_server"
      }
    ]
  end

  defp docs do
    [
      main: "DurableStash",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"],
      # These live in the sibling durable_server/live_stash packages and are
      # hidden there, so ExDoc can't link them — reference as plain code spans.
      skip_code_autolink_to: [
        "DurableServer.StorageBackend",
        "DurableServer.Backends.ObjectStore",
        "LiveStash.Application"
      ]
    ]
  end
end
