# bot_army_surface_mcp

The army-side MCP tool surface (repo: `ergon-mcp`). Registers, catalogs
and executes tools on behalf of MCP clients, with a NATS proxy for
downstream bots and semantic tool matching so fuzzy requests land on
the right tool.

## Subjects

| Subject | Direction | Purpose |
| --- | --- | --- |
| `bot_army.mcp.status` | request | service status |
| `bot_army.mcp.tools.execute` | request | execute a registered tool |
| `bot_army.mcp.tools.register` | request | register a tool |
| `bot_army.mcp.catalog.suggest` | request | semantic tool suggestions |
| `bot_army.mcp.config.get` / `.set` | request | army config access |

## Architecture

- `tool_discovery` + `catalog_store` / `catalog_fetcher` — the tool
  catalog and its discovery
- `semantic_tool_matcher` — fuzzy/semantic resolution for catalog
  suggestions
- `nats_proxy_service` — proxies tool execution to downstream bots
- `circuit_breaker` — bounded failure handling on proxied calls
- `pulse_publisher` — `system.health` pulses

## Development

```sh
mix deps.get
mix test
make publish-release
```

`config/runtime.exs` reads `NATS_HOST` / `NATS_PORT` at boot via
`ConfigLoader` so releases never bake in the dev broker.