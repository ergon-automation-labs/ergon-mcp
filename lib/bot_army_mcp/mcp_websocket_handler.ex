defmodule BotArmyMcp.MCPWebSocketHandler do
  @moduledoc """
  WebSocket handler for MCP protocol connections with agent context.

  Accepts WebSocket connections and routes JSON-RPC 2.0 MCP requests
  to the protocol handler. Returns responses as JSON.

  Maintains per-session agent context for:
  - Tracking Claude Code session identity
  - Tool call sequence numbering
  - User context (task ID, focus area)
  - Bot collaboration coordination
  """

  require Logger

  alias BotArmyMcp.AgentContext
  alias BotArmyMcp.MCPProtocol

  @doc "Cowboy WebSocket handler init callback"
  def init(req, _state) do
    # Create a new agent context for this WebSocket session
    agent_context = AgentContext.create()
    Logger.info("MCP session started: #{agent_context.session_id}")

    state = %{
      agent_context: agent_context
    }

    {:cowboy_websocket, req, state}
  end

  @doc "Handle incoming WebSocket frames"
  def websocket_handle({:text, data}, state) do
    case MCPProtocol.handle_request(data, state.agent_context) do
      {:ok, response, updated_context} ->
        {:reply, {:text, response}, %{state | agent_context: updated_context}}

      {:error, reason} ->
        Logger.error("MCP request error: #{inspect(reason)}")

        error_response =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "error" => %{"code" => -32_603, "message" => "Internal server error"}
          })

        {:reply, {:text, error_response}, state}
    end
  end

  def websocket_handle({:binary, _data}, state) do
    {:ok, state}
  end

  def websocket_handle(_frame, state) do
    {:ok, state}
  end

  @doc "Handle WebSocket connection info (e.g., timeout)"
  def websocket_info(_info, state) do
    {:ok, state}
  end
end
