defmodule BotArmyMcp.Application do
  @moduledoc """
  MCP Bot application supervisor.

  Follows bot army pattern with environment-aware startup:
  - Repo not started in :test (tests inject mocks)
  - PulsePublisher sends `system.health` liveness every 30s and rich `bot.<service>.pulse` every 30 minutes
  - Workers not started in :test (gated by @env)

  Observability: see `PulsePublisher` — fleet UIs keyed on Synapse hydration should use `system.health` freshness (90s), not pulse interval alone.
  """

  use Application

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    # Note: BotArmyLibraryRuntime.Telemetry and BotArmyLibraryRuntime.NATS.Connection are started
    # by bot_army_runtime automatically — do not add them here.

    children =
      []
      |> maybe_add_pulse_publisher()
      |> maybe_add_workers()

    opts = [strategy: :one_for_one, name: BotArmyMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_pulse_publisher(children) do
    if @env == :test do
      children
    else
      [{BotArmyMcp.PulsePublisher, []} | children]
    end
  end

  defp maybe_add_workers(children) do
    if @env == :test do
      children
    else
      # Bot-specific workers and pollers go here (GenServers that do async work)
      # Examples: Scheduler, Poller, Watcher
      # Pattern: gated with if @env == :test to prevent long-running processes in test
      # Phase 1 (Tool Discovery): ToolDiscovery, MCPServer
      # Phase 2 (Bidirectional Context): CircuitBreaker, AgentContextResponder
      [
        {BotArmyMcp.CircuitBreaker, []},
        {BotArmyMcp.ToolDiscovery, [cache_ttl_ms: 60_000]},
        {BotArmyMcp.MCPServer, [port: 14_223]},
        {BotArmyMcp.NATS.AgentContextResponder, []},
        {BotArmyMcp.CatalogStore, []},
        {BotArmyMcp.ConfigStore, []},
        {BotArmyMcp.CatalogFetcher, []},
        {BotArmyMcp.NATS.Consumer, []}
        | children
      ]
    end
  end
end
