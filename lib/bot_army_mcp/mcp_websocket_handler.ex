defmodule BotArmyMcp.MCPWebSocketHandler do
  @moduledoc """
  WebSocket handler for MCP protocol connections.

  Accepts WebSocket connections and routes JSON-RPC 2.0 MCP requests
  to the protocol handler. Returns responses as JSON.
  """

  require Logger

  alias BotArmyMcp.MCPProtocol

  @doc "Cowboy WebSocket handler init callback"
  def init(req, state) do
    {:cowboy_websocket, req, state}
  end

  @doc "Handle incoming WebSocket frames"
  def websocket_handle({:text, data}, state) do
    case MCPProtocol.handle_request(data) do
      {:ok, response} ->
        {:reply, {:text, response}, state}

      {:error, reason} ->
        Logger.error("MCP request error: #{inspect(reason)}")

        error_response =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "error" => %{"code" => -32603, "message" => "Internal server error"}
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
