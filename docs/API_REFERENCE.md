# API Reference: MCP Schema Enrichment

## Table of Contents
- [ToolDiscovery](#tooldiscovery)
- [SemanticToolMatcher](#semantictoolmatcher)
- [ContextAwareToolFilter](#contextawaretoolfilter)

---

## ToolDiscovery

Main entry point for tool discovery. Manages caching and coordinates semantic matching with context-aware filtering.

### `list_tools() :: {:ok, [tool]} | {:error, reason}`

Get all available MCP tools from the registry.

**Returns:**
- `{:ok, [tool]}` - List of available tools with metadata
- `{:error, reason}` - Connection or registry error

**Example:**
```elixir
{:ok, tools} = ToolDiscovery.list_tools()
# Returns tools with: name, description, timeout_ms, deployment_status, capabilities, schema
```

---

### `find_tools(query, opts \\ []) :: {:ok, [tool_with_score]} | {:error, reason}`

Find tools matching a natural language query using semantic matching.

**Parameters:**
- `query` (string) - Natural language query, e.g., "create task"
- `opts` (keyword list, optional):
  - `limit` - Max results (default: 10)
  - `min_score` - Minimum relevance score (default: 0.0)

**Returns:**
- `{:ok, [tool]}` - Tools ranked by semantic relevance, with added `:score` field
- `{:error, reason}` - Error reason

**Example:**
```elixir
{:ok, results} = ToolDiscovery.find_tools("create task", limit: 5)

Enum.each(results, fn tool ->
  IO.puts("#{tool.name}: #{tool.score}")
end)
# Output:
# gtd.task.create: 3.0
# gtd.task.update: 1.5
# gtd.task.list: 1.0
```

**Scoring:**
- Subject name match: 1.0 per token
- Description match: 0.5 per token
- Schema property match: 0.25 per token

---

### `find_tools_with_context(query, context \\ %{}, opts \\ []) :: {:ok, [tool_with_score]} | {:error, reason}`

Find tools with semantic matching AND context-aware filtering.

**Parameters:**
- `query` (string) - Natural language query
- `context` (map, optional) - System and user context:
  - `focus_mode` - "deep_work" | "shallow_work" | "break" (filters interrupting tools)
  - `max_timeout_ms` - Prefer tools with timeout ≤ this value
  - `min_health_score` - Minimum health threshold (0.0-1.0)
  - `bot_health_map` - Map of `bot_name -> "healthy"|"degraded"|"unhealthy"`
  - `intent` - User intent for capability matching
- `opts` (keyword list, optional):
  - `limit` - Max results (default: 10)
  - `include_degraded` - Include degraded bots (default: true)
  - `require_deployed` - Only return deployed tools (default: false)

**Returns:**
- `{:ok, [tool]}` - Tools ranked by semantic relevance + context appropriateness
- `{:error, reason}` - Error reason

**Example:**
```elixir
context = %{
  focus_mode: "deep_work",
  max_timeout_ms: 2000,
  bot_health_map: %{"gtd" => "healthy", "synapse" => "degraded"}
}

{:ok, results} = ToolDiscovery.find_tools_with_context("create task", context, limit: 3)
```

**Ranking:**
1. Semantic match (query relevance)
2. Context appropriateness:
   - Health: healthy (1.0) > degraded (0.7) > unhealthy (0.0)
   - Timeout: within budget (1.0) → over budget (penalized)
   - Capability: matches intent (0.8-1.0) or neutral (0.5)

---

### `refresh() :: :ok`

Force immediate refresh of tool catalog.

**Example:**
```elixir
ToolDiscovery.refresh()
# Clears cache and fetches fresh tool list from registry
```

---

## SemanticToolMatcher

Scores and ranks tools by relevance to natural language queries.

**Module:** `BotArmyMcp.SemanticToolMatcher`

### `find_tools(tools, query, opts \\ []) :: [tool_with_score]`

Find tools matching a query using keyword-based semantic scoring.

**Parameters:**
- `tools` ([tool]) - List of tools to search
- `query` (string) - Natural language query
- `opts` (keyword list, optional):
  - `limit` - Max results (default: 10)
  - `min_score` - Minimum relevance score (default: 0.0)

**Returns:**
- List of tools with added `:score` field, sorted by score (highest first)

**Example:**
```elixir
tools = [
  %{name: "gtd.task.create", description: "Create a task"},
  %{name: "gtd.task.list", description: "List all tasks"}
]

results = SemanticToolMatcher.find_tools(tools, "create task", limit: 1)
# [%{name: "gtd.task.create", score: 3.0}]
```

**Scoring Details:**
- Case-insensitive matching
- Multi-word query support
- Partial word matching (3+ char tokens)
- Tokenization by whitespace, hyphens, dots

---

### `score_tool(tool, query) :: float()`

Score a single tool against a query.

**Parameters:**
- `tool` (map) - Tool to score
- `query` (string) - Natural language query

**Returns:**
- Numeric score (0.0 or higher, higher = better match)

**Example:**
```elixir
tool = %{name: "gtd.task.create", description: "Create a task"}
score = SemanticToolMatcher.score_tool(tool, "create task")
# 3.0
```

---

## ContextAwareToolFilter

Filters and ranks tools based on system state and user context.

**Module:** `BotArmyMcp.ContextAwareToolFilter`

### `filter_tools(tools, context \\ %{}, opts \\ []) :: [tool_with_context_score]`

Filter and rank tools based on health, availability, and user context.

**Parameters:**
- `tools` ([tool]) - Tools to filter
- `context` (map, optional) - Context information:
  - `focus_mode` - "deep_work" (no interrupting tools) | "shallow_work" | "break"
  - `max_timeout_ms` - Prefer tools ≤ this timeout
  - `min_health_score` - Minimum health (0.0-1.0)
  - `bot_health_map` - Map of bot health status
  - `intent` - User intent for capability matching
- `opts` (keyword list, optional):
  - `limit` - Max results (default: 10)
  - `include_degraded` - Include degraded bots (default: true)
  - `require_deployed` - Only deployed tools (default: false)

**Returns:**
- List of tools with added `:context_score` field, sorted by score (highest first)

**Example:**
```elixir
tools = [...]
context = %{focus_mode: "deep_work", max_timeout_ms: 2000}

results = ContextAwareToolFilter.filter_tools(tools, context, limit: 5)
# Returns tools appropriate for deep_work, ranked by context score
```

**Filtering Rules:**
1. Remove disabled/archived (if not required_deployed)
2. Filter by focus_mode (deep_work removes messaging/notification)
3. Filter by health (remove if health < min_health_score)
4. Score by timeout suitability and capability match

---

### `score_with_context(tool, context \\ %{}) :: float()`

Score a tool against context.

**Parameters:**
- `tool` (map) - Tool to score
- `context` (map, optional) - Context information

**Returns:**
- Numeric score combining:
  - Health (0.3x weight): healthy=1.0, degraded=0.7, unhealthy=0.0
  - Timeout (0.2x weight): within budget=1.0, over=penalized
  - Capability (0.5x weight): intent matches=0.8-1.0, neutral=0.5

**Example:**
```elixir
tool = %{name: "gtd.task.create", timeout_ms: 2000}
context = %{max_timeout_ms: 5000}

score = ContextAwareToolFilter.score_with_context(tool, context)
# Returns combined health + timeout + capability score
```

---

## Data Structures

### Tool Map

```elixir
%{
  name: "gtd.task.create",                    # Subject name (required)
  description: "Create a task",               # Human-readable description
  timeout_ms: 2000,                           # Expected response time
  deployment_status: "deployed",              # "deployed"|"experimental"|"disabled"|"archived"
  capabilities: ["task_management", "gtd"],   # Bot capabilities
  inputSchema: %{                             # Optional input schema
    properties: %{
      "title" => %{"type" => "string"},
      "priority" => %{"type" => "string", "enum" => ["low", "normal", "high"]}
    },
    required: ["title"]
  }
}
```

### Context Map

```elixir
%{
  focus_mode: "deep_work",                    # "deep_work"|"shallow_work"|"break"
  max_timeout_ms: 2000,                       # Time budget in milliseconds
  min_health_score: 0.7,                      # Health threshold (0.0-1.0)
  bot_health_map: %{                          # Health status per bot
    "gtd" => "healthy",
    "synapse" => "degraded",
    "notification" => "unhealthy"
  },
  intent: "task_management"                   # User intent for capability matching
}
```

---

## Error Handling

All functions return either `{:ok, result}` or `{:error, reason}`:

```elixir
case ToolDiscovery.find_tools(query) do
  {:ok, tools} -> process(tools)
  {:error, :nats_connection_unavailable} -> handle_offline()
  {:error, :registry_timeout} -> retry_later()
end
```

---

## Performance Notes

- **Semantic matching:** O(n) linear scan
- **Context filtering:** O(n) with constant-time scoring
- **Combined:** ~1ms for 100 tools on modern hardware
- **Caching:** Tools cached for 60 seconds, configurable via `cache_ttl_ms`

---

## See Also

- [SCHEMA_ENRICHMENT.md](./SCHEMA_ENRICHMENT.md) - System overview and concepts
- [EXAMPLES.md](./EXAMPLES.md) - Usage examples and patterns
