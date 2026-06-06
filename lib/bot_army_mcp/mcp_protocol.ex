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
  Process an incoming MCP request and return a response.

  Expects JSON-RPC 2.0 format:
  {
    "jsonrpc": "2.0",
    "id": <number or string>,
    "method": "<method>",
    "params": {...}
  }
  """
  @spec handle_request(String.t()) :: {:ok, String.t()} | {:error, term()}
  def handle_request(json_string) do
    with {:ok, request} <- Jason.decode(json_string),
         {:ok, response} <- process_request(request) do
      {:ok, Jason.encode!(response)}
    else
      {:error, reason} ->
        error_response = error_response(nil, "Invalid request", reason)
        {:ok, Jason.encode!(error_response)}

      error ->
        error_response = error_response(nil, "Server error", inspect(error))
        {:ok, Jason.encode!(error_response)}
    end
  end

  # Private

  defp process_request(%{"jsonrpc" => "2.0", "method" => method} = request) do
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})

    case handle_method(method, params) do
      {:ok, result} ->
        {:ok, json_rpc_response(id, result)}

      {:error, error_msg} ->
        {:ok, error_response(id, error_msg, nil)}
    end
  end

  defp process_request(%{"jsonrpc" => _} = request) do
    id = Map.get(request, "id")
    {:ok, error_response(id, "Missing method", nil)}
  end

  defp process_request(_) do
    {:error, :invalid_json_rpc}
  end

  defp handle_method("initialize", _params) do
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
     }}
  end

  defp handle_method("tools/list", _params) do
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
         }}

      {:error, reason} ->
        {:error, "Failed to list tools: #{inspect(reason)}"}
    end
  end

  defp handle_method("tools/call", %{"name" => tool_name} = params) do
    arguments = Map.get(params, "arguments", %{})

    case NATSProxyService.call_tool(tool_name, arguments) do
      {:ok, result} ->
        {:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(result)}]}}

      {:error, reason} ->
        {:error, "Tool execution failed: #{inspect(reason)}"}
    end
  end

  defp handle_method(method, _params) do
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
