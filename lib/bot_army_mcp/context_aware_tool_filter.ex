defmodule BotArmyMcp.ContextAwareToolFilter do
  @moduledoc """
  Context-aware filtering and ranking of MCP tools.

  Filters tools based on:
  - Bot health and availability
  - Deployment status
  - User context (focus mode, time budget)
  - Tool capabilities matching intent
  - Timeout constraints

  Examples:
      iex> tools = [
      ...>   %{name: "gtd.task.create", timeout_ms: 2000, deployment_status: "deployed"},
      ...>   %{name: "gtd.task.list", timeout_ms: 1500, deployment_status: "deployed"}
      ...> ]
      iex> context = %{focus_mode: "break", max_timeout_ms: 3000}
      iex> BotArmyMcp.ContextAwareToolFilter.filter_tools(tools, context) |> Enum.map(fn t -> t.name end)
      ["gtd.task.create", "gtd.task.list"]

  Health Priority:
    - healthy: 1.0x multiplier
    - degraded: 0.7x multiplier (deprioritized)
    - unhealthy: 0.0 (filtered out by default)

  Deployment Status:
    - deployed: 1.0x multiplier
    - experimental: 0.8x multiplier
    - disabled: 0.0 (filtered out)
    - archived: 0.0 (filtered out)

  Focus Mode Effects:
    - deep_work: deprioritize interrupting tools (messages, notifications)
    - shallow_work: prefer quick tools (short timeout)
    - break: any tools available
  """

  require Logger

  @default_max_timeout_ms 10_000
  @default_min_health_score 0.5
  @health_weight 0.3
  @timeout_weight 0.2
  @capability_weight 0.5

  @doc """
  Filter and rank tools based on context.

  Returns list of tools with added `:context_score` field, sorted by score descending.

  Context map supports:
    - `:focus_mode` - "deep_work" | "shallow_work" | "break" (default: "break")
    - `:max_timeout_ms` - prefer tools with timeout <= this value (default: 10000)
    - `:min_health_score` - minimum health score to include (default: 0.5)
    - `:bot_health_map` - map of bot_name -> health_status
    - `:intent` - user intent for capability matching
    - `:skip_interrupting` - if true, skip notification/message tools in deep_work

  Options:
    - `:limit` - max results to return (default: 10)
    - `:include_degraded` - include degraded bots (default: true)
    - `:require_deployed` - only return deployed tools (default: false)
  """
  @spec filter_tools(list(map()), map(), Keyword.t()) :: list(map())
  def filter_tools(tools, context \\ %{}, opts \\ [])

  def filter_tools([], _context, _opts), do: []

  def filter_tools(tools, context, opts) when is_list(tools) and is_map(context) do
    focus_mode = Map.get(context, :focus_mode, "break")
    max_timeout = Map.get(context, :max_timeout_ms, @default_max_timeout_ms)
    min_health = Map.get(context, :min_health_score, @default_min_health_score)
    limit = Keyword.get(opts, :limit, 10)
    include_degraded = Keyword.get(opts, :include_degraded, true)
    require_deployed = Keyword.get(opts, :require_deployed, false)

    tools
    |> filter_by_deployment_status(require_deployed)
    |> filter_by_health(min_health, context)
    |> filter_by_focus_mode(focus_mode)
    |> Enum.map(fn tool ->
      score = score_with_context(tool, context)
      Map.put(tool, :context_score, score)
    end)
    |> filter_by_timeout(max_timeout)
    |> Enum.sort_by(fn tool -> -tool.context_score end)
    |> Enum.take(limit)
  end

  @doc """
  Score a single tool against context.

  Combines health score, timeout suitability, and capability matching.
  Returns a numeric score (0.0 or higher). Higher = better fit for context.
  """
  @spec score_with_context(map(), map()) :: float()
  def score_with_context(tool, context \\ %{}) when is_map(tool) and is_map(context) do
    max_timeout = Map.get(context, :max_timeout_ms, @default_max_timeout_ms)
    intent = Map.get(context, :intent)

    health_score = health_score(tool, context)
    timeout_score = timeout_suitability_score(tool, max_timeout)
    capability_score = capability_match_score(tool, intent)

    # Weighted combination
    health_score * @health_weight + timeout_score * @timeout_weight +
      capability_score * @capability_weight
  end

  # Private helpers

  defp filter_by_deployment_status(tools, false), do: tools

  defp filter_by_deployment_status(tools, true) do
    Enum.filter(tools, fn tool ->
      status = Map.get(tool, :deployment_status, "deployed")
      status == "deployed"
    end)
  end

  defp filter_by_health(tools, min_health, context) do
    # Filter out disabled/archived bots, and unhealthy bots if min_health > 0
    bot_health_map = Map.get(context, :bot_health_map, %{})

    Enum.filter(tools, fn tool ->
      status = Map.get(tool, :deployment_status, "deployed")

      if status in ["disabled", "archived"] do
        false
      else
        # Filter by health if min_health threshold is set
        bot_name = extract_bot_name(tool)
        health_status = Map.get(bot_health_map, bot_name) || infer_health_from_tool(tool)

        health_value =
          case health_status do
            "healthy" -> 1.0
            "degraded" -> 0.7
            "unhealthy" -> 0.0
            _ -> 0.8
          end

        health_value >= min_health
      end
    end)
  end

  defp filter_by_focus_mode(tools, "deep_work") do
    # Deprioritize interrupting tools by removing from results (they'll score low anyway)
    # Tools about messages, notifications, alerts, etc.
    Enum.filter(tools, fn tool ->
      name = Map.get(tool, :name, "")
      not String.contains?(name, ["message", "notification", "alert", "interrupt"])
    end)
  end

  defp filter_by_focus_mode(tools, _focus_mode), do: tools

  defp filter_by_timeout(tools, max_timeout) do
    # Reduce score for tools that exceed timeout, keep them in results
    Enum.map(tools, fn tool ->
      timeout_ms = Map.get(tool, :timeout_ms, 5000)

      if timeout_ms > max_timeout do
        # Penalize tools that exceed timeout, but keep them available
        adjusted_score = Map.get(tool, :context_score, 0.0) * 0.5
        Map.put(tool, :context_score, adjusted_score)
      else
        tool
      end
    end)
  end

  defp health_score(tool, context) do
    # Get health from context map if available, otherwise infer from tool metadata
    bot_name = extract_bot_name(tool)
    bot_health_map = Map.get(context, :bot_health_map, %{})

    health_status = Map.get(bot_health_map, bot_name) || infer_health_from_tool(tool)

    case health_status do
      "healthy" -> 1.0
      "degraded" -> 0.7
      "unhealthy" -> 0.0
      # Default to slightly healthy if unknown
      _ -> 0.8
    end
  end

  defp infer_health_from_tool(tool) do
    # Check if tool metadata has health indicators
    case {Map.get(tool, :health_status), Map.get(tool, :last_heartbeat)} do
      {"healthy", _} ->
        "healthy"

      {"degraded", _} ->
        "degraded"

      {"unhealthy", _} ->
        "unhealthy"

      {nil, timestamp} when is_integer(timestamp) ->
        # If heartbeat is recent (< 90s), consider healthy
        age_ms = System.system_time(:millisecond) - timestamp
        if age_ms < 90_000, do: "healthy", else: "degraded"

      _ ->
        "healthy"
    end
  end

  defp timeout_suitability_score(tool, max_timeout) do
    timeout_ms = Map.get(tool, :timeout_ms, 5000)

    cond do
      timeout_ms <= max_timeout -> 1.0
      timeout_ms <= max_timeout * 1.5 -> 0.8
      timeout_ms <= max_timeout * 2.0 -> 0.5
      true -> 0.2
    end
  end

  defp capability_match_score(tool, nil), do: 0.5

  defp capability_match_score(tool, intent) when is_binary(intent) do
    capabilities = Map.get(tool, :capabilities, [])

    if Enum.empty?(capabilities) do
      # No capability info, neutral score
      0.5
    else
      # Check if intent matches any capability (simple substring matching)
      match_count =
        Enum.count(capabilities, fn cap ->
          cap_str = if is_atom(cap), do: Atom.to_string(cap), else: cap

          String.contains?(String.downcase(intent), String.downcase(cap_str)) ||
            String.contains?(String.downcase(cap_str), String.downcase(intent))
        end)

      if match_count > 0 do
        # Score based on match quality: 1 match = 0.8, 2+ = 1.0
        min(1.0, 0.8 + match_count * 0.1)
      else
        0.5
      end
    end
  end

  defp extract_bot_name(tool) do
    # Extract bot name from subject (e.g., "gtd.task.create" -> "gtd")
    case Map.get(tool, :name) do
      name when is_binary(name) ->
        name
        |> String.split(".")
        |> List.first()

      _ ->
        "unknown"
    end
  end
end
