import Config

# Logger with correlation_id support
config :logger,
  level: :info,
  backends: [:console],
  default_formatter: {BotArmyRuntime.LoggerFormatter, []}

config :logger, :console,
  format: {BotArmyRuntime.LoggerFormatter, []},
  metadata: [:correlation_id]

config :bot_army_mcp, :deployment_status, "experimental"

