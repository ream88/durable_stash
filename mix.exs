defmodule DurableStash.MixProject do
  use Mix.Project

  def project do
    [
      app: :durable_stash,
      version: "0.1.0",
      description: "Durable session-scoped state for LiveView",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
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
      {:live_stash, "~> 0.3"},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
