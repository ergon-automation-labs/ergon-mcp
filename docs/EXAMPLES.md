# MCP Schema Enrichment: Examples

Practical examples showing how to use the schema enrichment system.

## Table of Contents
1. [Basic Semantic Search](#basic-semantic-search)
2. [Context-Aware Discovery](#context-aware-discovery)
3. [Real-World Scenarios](#real-world-scenarios)
4. [Advanced Patterns](#advanced-patterns)

---

## Basic Semantic Search

### Example 1: Find task management tools

```elixir
{:ok, tools} = ToolDiscovery.find_tools("create task", limit: 5)

Enum.each(tools, fn tool ->
  IO.puts("#{tool.name} - #{tool.description}")
  IO.puts("  Score: #{tool.score}")
  IO.puts("")
end)

# Output:
# gtd.task.create - Create a new task
#   Score: 3.0
# gtd.task.update - Update an existing task
#   Score: 1.5
# gtd.task.list - List all tasks
#   Score: 1.0
```

### Example 2: Search by capability

```elixir
{:ok, tools} = ToolDiscovery.find_tools("manage")

# Filter to only task management
task_tools = Enum.filter(tools, fn tool ->
  Enum.any?(tool.capabilities || [], &String.contains?(&1, "task"))
end)

IO.inspect(Enum.map(task_tools, & &1.name))
# ["gtd.task.create", "gtd.task.update", "gtd.task.list"]
```

### Example 3: Limit results and set minimum score

```elixir
{:ok, high_relevance} = ToolDiscovery.find_tools(
  "send message",
  limit: 3,
  min_score: 1.5  # Only highly relevant matches
)

IO.puts("High relevance matches: #{length(high_relevance)}")
```

---

## Context-Aware Discovery

### Example 1: Deep work mode (focus)

User is in deep work and wants to manage tasks:

```elixir
context = %{
  focus_mode: "deep_work",        # Minimize interruptions
  max_timeout_ms: 2000,           # Need fast responses
  bot_health_map: %{
    "gtd" => "healthy",
    "synapse" => "degraded",      # Messaging bot is degraded
    "notification" => "unhealthy"  # Don't use notifications
  }
}

{:ok, tools} = ToolDiscovery.find_tools_with_context(
  "create task",
  context,
  limit: 5
)

# Results will be:
# ✓ gtd.task.create (healthy, 2.0s timeout, task capability)
# ✗ synapse.message.send (excluded in deep_work)
# ✗ notification.push (unhealthy)
```

### Example 2: Shallow work mode (quick operations)

User has a short break and wants quick operations:

```elixir
context = %{
  focus_mode: "shallow_work",
  max_timeout_ms: 1500,           # Very fast preferred
  bot_health_map: %{"gtd" => "healthy"}
}

{:ok, tools} = ToolDiscovery.find_tools_with_context(
  "what are my tasks",
  context,
  limit: 3
)

# Prefers:
# ✓ gtd.task.list (1.5s, fast enough)
# ✗ search.advanced (5.0s, too slow)
```

### Example 3: System health monitoring

Synapse is degraded, find alternative communication:

```elixir
context = %{
  bot_health_map: %{
    "synapse" => "degraded",
    "notification" => "unhealthy"
  },
  min_health_score: 0.7  # Exclude unhealthy
}

{:ok, tools} = ToolDiscovery.find_tools_with_context(
  "send notification",
  context,
  limit: 5
)

# Results deprioritize degraded, exclude unhealthy
# Suggests alternative notification methods if available
```

---

## Real-World Scenarios

### Scenario 1: Morning Planning Session

User wakes up, wants to plan their day (typical deep work):

```elixir
defmodule DailyPlanner do
  def plan_day() do
    context = morning_context()
    
    # Step 1: See what's already planned
    {:ok, list_tools} = ToolDiscovery.find_tools_with_context(
      "what tasks am I working on",
      context,
      limit: 1
    )
    
    current_tasks = execute_tool(list_tools, [])
    
    # Step 2: Add new tasks for today
    {:ok, create_tools} = ToolDiscovery.find_tools_with_context(
      "add new task",
      context,
      limit: 1
    )
    
    new_task = execute_tool(create_tools, [
      title: "Review morning emails",
      priority: "normal"
    ])
    
    {:ok, current_tasks ++ [new_task]}
  end
  
  defp morning_context() do
    %{
      focus_mode: "deep_work",
      max_timeout_ms: 2000,
      bot_health_map: get_bot_health(),
      intent: "task_planning"
    }
  end
end
```

### Scenario 2: Afternoon Context Switch

User transitions from deep work to meetings/communication:

```elixir
defmodule ContextSwitch do
  def afternoon_update() do
    # Was in deep_work, now switching to shallow_work (meetings)
    context = %{
      focus_mode: "shallow_work",
      max_timeout_ms: 3000,  # More lenient on time
      bot_health_map: get_bot_health()
    }
    
    # Find tools for quick communication
    {:ok, tools} = ToolDiscovery.find_tools_with_context(
      "send updates to team",
      context,
      limit: 3
    )
    
    # Now messaging tools become available (not in deep_work)
    Enum.filter(tools, fn tool ->
      Enum.any?(tool.capabilities || [], &String.contains?(&1, "messaging"))
    end)
  end
end
```

### Scenario 3: Service Recovery

Synapse messaging bot is degraded, system needs to continue:

```elixir
defmodule ServiceRecovery do
  def send_critical_message(message) do
    context = %{
      bot_health_map: %{
        "synapse" => "degraded",
        "slack_bridge" => "healthy"  # Alternative available
      },
      min_health_score: 0.7
    }
    
    {:ok, tools} = ToolDiscovery.find_tools_with_context(
      "notify team",
      context,
      limit: 3
    )
    
    # Will deprioritize synapse, suggest slack_bridge if available
    best_tool = Enum.max_by(tools, & &1.context_score)
    execute_critical_message(best_tool, message)
  end
end
```

---

## Advanced Patterns

### Pattern 1: Multi-Step Workflow with Context Awareness

```elixir
defmodule TaskWorkflow do
  def complete_daily_workflow() do
    context = current_context()
    
    # Step 1: List high-priority tasks
    {:ok, [list_tool | _]} = ToolDiscovery.find_tools_with_context(
      "show priority tasks",
      context,
      limit: 1
    )
    
    tasks = execute(list_tool)
    
    # Step 2: For each task, find appropriate update tool
    Enum.map(tasks, fn task ->
      {:ok, [update_tool | _]} = ToolDiscovery.find_tools_with_context(
        "mark task progress",
        context,
        limit: 1,
        require_deployed: true  # Only stable tools
      )
      
      execute(update_tool, [task_id: task.id, progress: "in_progress"])
    end)
  end
  
  defp current_context() do
    %{
      focus_mode: detect_focus_mode(),
      max_timeout_ms: available_time_budget(),
      bot_health_map: fetch_bot_health(),
      intent: "productivity"
    }
  end
end
```

### Pattern 2: Capability-Based Tool Selection

```elixir
defmodule CapabilityMatcher do
  def find_by_capability(user_intent, available_time_ms) do
    context = %{
      intent: user_intent,
      max_timeout_ms: available_time_ms,
      bot_health_map: get_health()
    }
    
    # Find tools matching the intent
    {:ok, tools} = ToolDiscovery.find_tools_with_context(
      user_intent,
      context,
      limit: 10
    )
    
    # Re-rank by capability match strength
    tools
    |> Enum.map(&add_capability_confidence/1)
    |> Enum.sort_by(&capability_confidence/1, :desc)
    |> Enum.take(3)
  end
  
  defp add_capability_confidence(tool) do
    confidence = calculate_capability_match(tool.capabilities, tool_intent)
    Map.put(tool, :capability_confidence, confidence)
  end
  
  defp capability_confidence(%{capability_confidence: conf}), do: conf
  defp capability_confidence(_), do: 0.0
end
```

### Pattern 3: Health-Aware Fallback Chain

```elixir
defmodule HealthAwareFallback do
  def execute_with_fallback(query) do
    context = %{bot_health_map: get_bot_health()}
    
    {:ok, tools} = ToolDiscovery.find_tools_with_context(
      query,
      context,
      limit: 5
    )
    
    # Try tools in order of health/context score
    execute_chain(tools)
  end
  
  defp execute_chain([]), do: {:error, :no_tools_available}
  
  defp execute_chain([tool | rest]) do
    case execute_safely(tool) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} ->
        IO.puts("Tool #{tool.name} failed, trying next...")
        execute_chain(rest)
    end
  end
end
```

### Pattern 4: Dynamic Tool Selection Based on Load

```elixir
defmodule DynamicLoad do
  def smart_tool_selection(query) do
    current_load = get_system_load()
    
    context = %{
      bot_health_map: get_bot_health(),
      # Adjust timeout based on system load
      max_timeout_ms: timeout_for_load(current_load),
      # In high-load, focus on essential capabilities
      intent: essential_intent_for_load(current_load)
    }
    
    {:ok, tools} = ToolDiscovery.find_tools_with_context(
      query,
      context,
      limit: 1  # Pick the single best tool
    )
    
    tools
  end
  
  defp timeout_for_load(:high), do: 1000
  defp timeout_for_load(:normal), do: 3000
  defp timeout_for_load(:low), do: 5000
  
  defp essential_intent_for_load(:high), do: "critical"
  defp essential_intent_for_load(_), do: nil
end
```

---

## Integration Patterns

### Using with External Systems

```elixir
# With Phoenix LiveView
def mount(_params, _session, socket) do
  {:ok, tools} = ToolDiscovery.find_tools_with_context(
    "recent activity",
    current_user_context(socket.assigns.current_user)
  )
  
  {:ok, assign(socket, available_tools: tools)}
end

# With GenServer
def handle_call({:find_tools, query, context}, _from, state) do
  {:ok, tools} = ToolDiscovery.find_tools_with_context(query, context)
  {:reply, tools, state}
end

# With Broadway for streaming
def handle_message(_module, message, _context) do
  {:ok, tools} = ToolDiscovery.find_tools_with_context(
    extract_intent(message),
    streaming_context()
  )
  
  Message.update_data(message, :tools, tools)
end
```

---

## Troubleshooting

### No tools returned

```elixir
# Debug: What tools exist?
{:ok, all_tools} = ToolDiscovery.list_tools()
IO.puts("Available: #{length(all_tools)} tools")

# Try broader query
{:ok, broader} = ToolDiscovery.find_tools("task")
IO.puts("Broader query: #{length(broader)} results")

# Check context isn't too restrictive
context = %{
  max_timeout_ms: 10000,  # Increase timeout
  min_health_score: 0.0,  # Lower health requirement
  bot_health_map: %{}     # Clear health map
}
{:ok, results} = ToolDiscovery.find_tools_with_context(query, context)
```

### Tools in wrong order

```elixir
# Check semantic scores
{:ok, tools} = ToolDiscovery.find_tools(query, limit: 5)
Enum.map(tools, &{&1.name, &1.score})

# Check context scores
results = ContextAwareToolFilter.filter_tools(tools, context)
Enum.map(results, &{&1.name, &1.context_score})

# Verify bot health is correct
bot_health = get_bot_health()
IO.inspect(bot_health)
```

---

## Next Steps

- Read [SCHEMA_ENRICHMENT.md](./SCHEMA_ENRICHMENT.md) for system overview
- Check [API_REFERENCE.md](./API_REFERENCE.md) for detailed API docs
- Review integration tests in `test/bot_army_mcp/tool_discovery_integration_test.exs`
