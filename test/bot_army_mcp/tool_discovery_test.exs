defmodule BotArmyMcp.ToolDiscoveryTest do
  use ExUnit.Case
  @moduletag :integration

  alias BotArmyMcp.ToolDiscovery

  describe "list_tools/0" do
    test "returns list of available MCP tools" do
      # Start discovery module
      {:ok, _pid} = ToolDiscovery.start_link(cache_ttl_ms: 60_000)

      # Give it time to fetch from registry
      Process.sleep(2000)

      case ToolDiscovery.list_tools() do
        {:ok, tools} ->
          # Should have at least some tools from active bots
          assert is_list(tools)
          assert length(tools) > 0

          # Each tool should have required fields
          Enum.each(tools, fn tool ->
            assert is_map(tool)
            assert Map.has_key?(tool, :name)
            assert Map.has_key?(tool, :description)
            assert Map.has_key?(tool, :inputSchema)
            assert Map.has_key?(tool, :timeout_ms)
          end)

        {:error, reason} ->
          # Registry unavailable is acceptable in test
          assert reason in [:nats_connection_unavailable, :registry_timeout]
      end
    end

    test "filters out system subjects" do
      {:ok, _pid} = ToolDiscovery.start_link(cache_ttl_ms: 60_000)
      Process.sleep(2000)

      case ToolDiscovery.list_tools() do
        {:ok, tools} ->
          # Should not include system.health.* subjects
          tool_names = Enum.map(tools, & &1.name)

          assert not Enum.any?(tool_names, &String.starts_with?(&1, "system."))
          assert not Enum.any?(tool_names, &String.starts_with?(&1, "bot_army.registry."))

        {:error, _} ->
          :ok
      end
    end
  end

  describe "refresh/0" do
    test "forces immediate tool refresh" do
      {:ok, _pid} = ToolDiscovery.start_link(cache_ttl_ms: 999_999_999)

      # Initial list
      case ToolDiscovery.list_tools() do
        {:ok, initial_tools} ->
          initial_count = length(initial_tools)

          # Refresh
          ToolDiscovery.refresh()
          Process.sleep(1000)

          # Should get fresh list
          case ToolDiscovery.list_tools() do
            {:ok, refreshed_tools} ->
              # Counts should be similar (might change if bots deployed/undeployed)
              assert length(refreshed_tools) == initial_count

            {:error, _} ->
              :ok
          end

        {:error, _} ->
          :ok
      end
    end
  end
end
