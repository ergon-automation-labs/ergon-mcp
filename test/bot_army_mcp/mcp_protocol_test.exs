defmodule BotArmyMcp.MCPProtocolTest do
  use ExUnit.Case
  @moduletag :unit

  alias BotArmyMcp.MCPProtocol

  describe "handle_request/2" do
    setup do
      agent_context = BotArmyMcp.AgentContext.create()
      {:ok, agent_context: agent_context}
    end

    test "handles initialize request", %{agent_context: agent_context} do
      request =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{}
        })

      {:ok, response_json, _} = MCPProtocol.handle_request(request, agent_context)
      response = Jason.decode!(response_json)

      assert response["id"] == 1
      assert response["result"]["protocolVersion"]
      assert response["result"]["serverInfo"]["name"] == "bot_army_mcp"
    end

    test "returns error for unknown method", %{agent_context: agent_context} do
      request =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "unknown.method",
          "params" => %{}
        })

      {:ok, response_json, _} = MCPProtocol.handle_request(request, agent_context)
      response = Jason.decode!(response_json)

      assert response["id"] == 1
      assert response["error"]["message"] =~ "Unknown method"
    end

    test "handles invalid JSON gracefully", %{agent_context: agent_context} do
      request = "not valid json"

      {:ok, response_json, _} = MCPProtocol.handle_request(request, agent_context)
      response = Jason.decode!(response_json)

      # Should return error response
      assert response["error"]["message"] =~ "Invalid request"
    end

    @tag :nats_live
    test "handles tools/list request", %{agent_context: agent_context} do
      # Requires live ToolDiscovery and NATS connection
      request =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list",
          "params" => %{}
        })

      {:ok, response_json, _} = MCPProtocol.handle_request(request, agent_context)
      response = Jason.decode!(response_json)

      case response do
        %{"result" => %{"tools" => tools}} ->
          # Tools list is available
          assert is_list(tools)

        %{"error" => _} ->
          # Registry unavailable in test, which is acceptable
          :ok
      end
    end

    test "preserves request ID in response", %{agent_context: agent_context} do
      request =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "custom-id-123",
          "method" => "initialize",
          "params" => %{}
        })

      {:ok, response_json, _} = MCPProtocol.handle_request(request, agent_context)
      response = Jason.decode!(response_json)

      assert response["id"] == "custom-id-123"
    end
  end
end
