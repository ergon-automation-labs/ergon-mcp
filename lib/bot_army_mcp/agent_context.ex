defmodule BotArmyMcp.AgentContext do
  @moduledoc """
  Manages Claude agent context for MCP tool calls.

  Each tool invocation carries context about the Claude Code session:
  - session_id: unique identifier for this Claude session
  - timestamp: when the request was made
  - source: always "claude_code" for Phase 2
  - user_context: optional user-provided context (task ID, focus area, etc.)

  This context flows to Bot Army bots via NATS, allowing them to:
  - Tailor responses based on agent presence
  - Coordinate across multiple tool calls
  - Adapt behavior to user focus
  - Track inter-bot collaboration patterns
  """

  require Logger

  @doc """
  Create a new agent context for this tool invocation.

  Called once per WebSocket connection (or session).
  """
  @spec create() :: map()
  def create do
    %{
      session_id: generate_session_id(),
      created_at: DateTime.utc_now(),
      call_count: 0
    }
  end

  @doc """
  Build context envelope for a NATS request.

  Includes agent metadata to be sent alongside tool arguments.
  Bots can query this via bot_army.agent.context.get or read from request envelope.
  """
  @spec build_envelope(map(), String.t(), map()) :: map()
  def build_envelope(agent_context, tool_name, arguments) do
    %{
      command: arguments,
      agent_context: %{
        session_id: agent_context.session_id,
        source: "claude_code",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        tool_name: tool_name,
        call_sequence: agent_context.call_count + 1
      }
    }
  end

  @doc """
  Register a tool call (increment sequence number).

  Call this after each tool invocation to track call order.
  """
  @spec register_call(map()) :: map()
  def register_call(agent_context) do
    %{agent_context | call_count: agent_context.call_count + 1}
  end

  @doc """
  Inject user context into agent session.

  Optional: associates Claude session with user task/focus.
  """
  @spec with_user_context(map(), String.t(), map()) :: map()
  def with_user_context(agent_context, task_id, metadata \\ %{}) do
    Map.put(agent_context, :user_context, %{
      task_id: task_id,
      metadata: metadata,
      set_at: DateTime.utc_now()
    })
  end

  @doc """
  Clear user context (when user switches focus).
  """
  @spec clear_user_context(map()) :: map()
  def clear_user_context(agent_context) do
    Map.delete(agent_context, :user_context)
  end

  @doc """
  Get session context for debugging/logging.
  """
  @spec summary(map()) :: map()
  def summary(agent_context) do
    %{
      session_id: agent_context.session_id,
      created_at: agent_context.created_at,
      calls_made: agent_context.call_count,
      has_user_context: Map.has_key?(agent_context, :user_context)
    }
  end

  # Private

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
