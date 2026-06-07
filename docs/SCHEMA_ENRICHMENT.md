# MCP Schema Enrichment System

## Overview

The MCP Schema Enrichment System enables intelligent tool discovery and selection for the Bot Army ecosystem through a four-layer enhancement pipeline:

1. **Schema Metadata** (Task 1-2) - Registry supports optional input schemas on tools
2. **Semantic Matching** (Task 3) - Natural language queries find tools by meaning
3. **Context-Aware Filtering** (Task 4) - System state drives tool ranking
4. **Integration Testing** (Task 5) - E2E validation and documentation

## Key Concepts

### Tool Discovery Layers

**Traditional Discovery:** Tool name + description matching
```
Query: "create task"
Result: [gtd.task.create, gtd.task.list, gtd.task.update, ...]
```

**With Semantic Matching:** Keyword-based scoring of relevance
```
Query: "create task"
Results ranked by: subject match (1.0x) > description match (0.5x) > properties (0.25x)
Top: gtd.task.create (score: 3.0)
```

**With Context Filtering:** System state drives ranking
```
Query: "create task" + Context: deep_work, health=healthy, timeout<2s
Results: [gtd.task.create (healthy, 2.0s timeout, task capability match)]
Excluded: [synapse.message.send (messaging ≠ deep_work)]
```

### Context Dimensions

**User Context:**
- Focus mode: deep_work (minimize interruptions), shallow_work (quick ops), break (any)
- Time budget: max_timeout_ms (prefer fast tools when constrained)
- Intent: user's semantic goal for capability matching

**System Context:**
- Bot health: healthy (1.0) > degraded (0.7) > unhealthy (0.0)
- Deployment status: deployed > experimental > disabled/archived
- Availability: recent heartbeat indicates active bot

### Schema Metadata Structure

```json
{
  "subject": "gtd.task.create",
  "type": "request_reply",
  "description": "Create a task",
  "timeout_ms": 2000,
  "deployment_status": "deployed",
  "capabilities": ["task_management", "gtd"],
  "schema": {
    "properties": {
      "title": {"type": "string"},
      "priority": {"type": "string", "enum": ["low", "normal", "high"]}
    },
    "required": ["title"]
  }
}
```

## Usage Patterns

### Pattern 1: Simple Semantic Search

Find tools by what you want to do:

```elixir
ToolDiscovery.find_tools("create task", limit: 5)
# Returns top 5 tools ranked by semantic relevance
```

### Pattern 2: Context-Aware Discovery

Find tools appropriate for current situation:

```elixir
context = %{
  focus_mode: "deep_work",
  max_timeout_ms: 2000,
  bot_health_map: %{"synapse" => "degraded"}
}

ToolDiscovery.find_tools_with_context("create task", context, limit: 5)
# Returns tools that are:
# - Relevant to "create task" (semantic)
# - Appropriate for deep_work (no notifications)
# - Available (healthy bots)
# - Fast (< 2s timeout)
```

### Pattern 3: Intent-Based Capability Matching

Find tools by user intent and bot capabilities:

```elixir
context = %{
  intent: "task_management",
  max_timeout_ms: 3000,
  bot_health_map: %{"gtd" => "healthy"}
}

ToolDiscovery.find_tools_with_context("organize", context)
# Returns tools with task_management capability,
# ranked by health and timeout suitability
```

## Real-World Scenarios

### Scenario 1: Morning Planning Session (deep_work)

User: "I need to plan my day"

```elixir
context = %{
  focus_mode: "deep_work",      # Minimize interruptions
  max_timeout_ms: 2000,         # Quick responses
  bot_health_map: current_health()
}

ToolDiscovery.find_tools_with_context("plan day", context, limit: 3)
```

Results prioritize:
- Task management tools (capability match)
- Fast execution (timeout < 2s)
- Healthy bots only
- Excludes: messaging, notifications

### Scenario 2: Shallow Work Break (multitasking)

User: "Quick check - what messages do I have?"

```elixir
context = %{
  focus_mode: "shallow_work",   # Any tools ok
  max_timeout_ms: 1000,         # Very fast preferred
  bot_health_map: current_health()
}

ToolDiscovery.find_tools_with_context("check messages", context, limit: 5)
```

Results prioritize:
- Fast operations
- Can include degraded services if needed
- Messaging capability match

### Scenario 3: System Recovery (health monitoring)

User: "Synapse is degraded, find alternative tools"

```elixir
context = %{
  bot_health_map: %{
    "synapse" => "degraded",
    "notification" => "unhealthy"
  },
  min_health_score: 0.7  # Exclude unhealthy
}

ToolDiscovery.find_tools_with_context("communicate", context)
```

Results:
- Excludes unhealthy services
- Deprioritizes degraded services
- Finds alternative communication paths

## Scoring Algorithm

### Semantic Matching Score (Task 3)

```
score = (
  subject_tokens_matched * 1.0 +      # "task.create" matches "create" strongly
  description_tokens_matched * 0.5 +  # "Create a task" partial match
  property_tokens_matched * 0.25      # "priority" property matches query
)
```

### Context-Aware Score (Task 4)

```
combined_score = (
  health_score * 0.3 +          # healthy=1.0, degraded=0.7, unhealthy=0.0
  timeout_score * 0.2 +         # within budget=1.0, over=penalized
  capability_score * 0.5        # intent matches=0.8-1.0, neutral=0.5
)
```

Final ranking: Semantic match + Context score = Overall relevance

## Integration with Registry

The system integrates with the Bot Army registry:

1. **Registry stores schema metadata** - Subjects can include optional `schema` field
2. **ToolDiscovery queries registry** - Fetches all tools with metadata
3. **Semantic matching ranks** - Scores by query relevance
4. **Context filtering refines** - Applies system state constraints
5. **Final ranking** - Combined semantic + context score

## Error Handling

The system gracefully handles:
- **Missing schema metadata** - Tools without schemas still work (neutral scoring)
- **Unavailable health data** - Defaults to healthy (optimistic)
- **Degraded services** - Deprioritizes but doesn't exclude (fallback available)
- **Empty results** - Returns empty list, caller can retry with broader query
- **Large tool sets** - Efficient filtering and ranking for 100+ tools

## Performance Characteristics

- **Semantic matching:** O(n) where n = number of tools
- **Context filtering:** O(n) with constant-time scoring
- **Combined:** O(n) total, typically sub-millisecond for 100 tools
- **Caching:** ToolDiscovery caches tools, 60s TTL default

## Backwards Compatibility

- No breaking changes to existing APIs
- New features (context filtering, schema metadata) are opt-in
- Legacy code using `find_tools(query)` continues working
- New code can leverage `find_tools_with_context(query, context)`

## Next Steps

1. **Try semantic discovery** - Use `ToolDiscovery.find_tools("your query")`
2. **Add context** - Use `find_tools_with_context` with focus_mode/health data
3. **Register schemas** - Add optional `schema` to bot subjects in registry
4. **Monitor health** - Provide bot_health_map from your context broker

## Examples

See [EXAMPLES.md](./EXAMPLES.md) for complete working examples including:
- Basic semantic search
- Context-aware filtering
- Capability matching
- Health-aware ranking
- Multi-tool selection patterns
