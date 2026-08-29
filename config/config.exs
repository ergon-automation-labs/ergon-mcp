import Config

# Logger with correlation_id support
config :logger,
  level: :info,
  backends: [:console]

config :logger, :console,
  format: "[$time] [$level] $message\n",
  metadata: [:correlation_id]

config :bot_army_mcp, :deployment_status, "experimental"

# What `tools/list` surfaces and what `tools/call` accepts:
#   :curated -> only the curated bridge tools (default; limits Claude Desktop)
#   :all     -> curated tools + every request_reply subject discovered from the fleet
config :bot_army_mcp, :tools_mode, :curated

