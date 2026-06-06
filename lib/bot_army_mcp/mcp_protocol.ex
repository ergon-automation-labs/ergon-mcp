defmodule BotArmyMcp.MCPProtocol do
  @moduledoc """
  Implements the Model Context Protocol (MCP) using JSON-RPC 2.0.

  Handles MCP requests and responses:
  - initialize: Handshake with Claude
  - tools/list: Return available MCP tools
  - tools/call: Execute a tool via NATS

  Uses JSON-RPC 2.0 message format with optional request IDs.
  """

  require Logger

  alias BotArmyMcp.ToolDiscovery
  alias BotArmyMcp.NATSProxyService

  @mcp_version "2024-11-05"
  @server_name "bot_army_mcp"
  @server_version Mix.Project.config()[:version]

  @doc """
  Process an incoming MCP request and return a response with updated agent context.

  Expects JSON-RPC 2.0 format:
  {
    "jsonrpc": "2.0",
    "id": <number or string>,
    "method": "<method>",
    "params": {...}
  }

  Returns: {:ok, response_json, updated_agent_context} | {:error, reason}
  """
  @spec handle_request(String.t(), map()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def handle_request(json_string, agent_context) do
    with {:ok, request} <- Jason.decode(json_string),
         {:ok, response, updated_context} <- process_request(request, agent_context) do
      {:ok, Jason.encode!(response), updated_context}
    else
      {:error, reason} ->
        error_response = error_response(nil, "Invalid request", reason)
        {:ok, Jason.encode!(error_response), agent_context}

      error ->
        error_response = error_response(nil, "Server error", inspect(error))
        {:ok, Jason.encode!(error_response), agent_context}
    end
  end

  # Private

  alias BotArmyMcp.AgentContext

  defp process_request(%{"jsonrpc" => "2.0", "method" => method} = request, agent_context) do
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})

    case handle_method(method, params, agent_context) do
      {:ok, result, updated_context} ->
        {:ok, json_rpc_response(id, result), updated_context}

      {:error, error_msg} ->
        {:ok, error_response(id, error_msg, nil), agent_context}
    end
  end

  defp process_request(%{"jsonrpc" => _} = request, agent_context) do
    id = Map.get(request, "id")
    {:ok, error_response(id, "Missing method", nil), agent_context}
  end

  defp process_request(_, _agent_context) do
    {:error, :invalid_json_rpc}
  end

  defp handle_method("initialize", _params, agent_context) do
    {:ok,
     %{
       "protocolVersion" => @mcp_version,
       "capabilities" => %{
         "tools" => %{},
         "resources" => %{}
       },
       "serverInfo" => %{
         "name" => @server_name,
         "version" => @server_version
       }
     }, agent_context}
  end

  defp handle_method("tools/list", _params, agent_context) do
    case ToolDiscovery.list_tools() do
      {:ok, tools} ->
        {:ok,
         %{
           "tools" =>
             Enum.map(tools, fn tool ->
               %{
                 "name" => tool.name,
                 "description" => tool.description,
                 "inputSchema" => tool.inputSchema
               }
             end)
         }, agent_context}

      {:error, reason} ->
        {:error, "Failed to list tools: #{inspect(reason)}"}
    end
  end

  defp handle_method("tools/call", %{"name" => tool_name} = params, agent_context) do
    arguments = Map.get(params, "arguments", %{})

    case NATSProxyService.call_tool(tool_name, arguments, agent_context) do
      {:ok, result} ->
        updated_context = AgentContext.register_call(agent_context)

        {:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(result)}]},
         updated_context}

      {:error, reason} ->
        {:error, "Tool execution failed: #{inspect(reason)}"}
    end
  end

  defp handle_method(method, _params, _agent_context) do
    {:error, "Unknown method: #{method}"}
  end

  defp json_rpc_response(id, result) when is_nil(id) do
    %{"jsonrpc" => "2.0", "result" => result}
  end

  defp json_rpc_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, message, data) when is_nil(id) do
    error_body = %{"code" => -32603, "message" => message}
    error_body = if data, do: Map.put(error_body, "data", data), else: error_body
    %{"jsonrpc" => "2.0", "error" => error_body}
  end

  defp error_response(id, message, data) do
    error_body = %{"code" => -32603, "message" => message}
    error_body = if data, do: Map.put(error_body, "data", data), else: error_body
    %{"jsonrpc" => "2.0", "id" => id, "error" => error_body}
  end
end
