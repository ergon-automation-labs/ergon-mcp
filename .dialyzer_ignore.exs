[
  # Pre-existing: @env Mix.env() compile-time branching; dialyzer sees :dev == :test as impossible.
  # Pattern used fleet-wide; fixing requires runtime Application.get_env with performance cost.
  {"lib/bot_army_mcp/application.ex", :exact_eq},

  # Pre-existing: cross-app module references dialyzer cannot resolve in umbrella.
  {"lib/bot_army_mcp/nats/consumer.ex", :unknown_function},
  {"lib/bot_army_mcp/nats/consumer.ex", :call_to_missing}
]
