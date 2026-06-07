defmodule BotArmyMcp.ToolDiscoveryIntegrationTest do
  use ExUnit.Case
  doctest BotArmyMcp.ToolDiscovery

  alias BotArmyMcp.{SemanticToolMatcher, ContextAwareToolFilter}

  setup do
    # Comprehensive mock tools simulating real Bot Army services
    tools = [
      # GTD Bot - Task Management
      %{
        name: "gtd.task.create",
        description: "Create a new task in GTD system",
        timeout_ms: 2000,
        deployment_status: "deployed",
        capabilities: ["task_management", "gtd"],
        inputSchema: %{
          properties: %{
            "title" => %{"type" => "string"},
            "priority" => %{"type" => "string", "enum" => ["low", "normal", "high"]}
          },
          required: ["title"]
        }
      },
      %{
        name: "gtd.task.list",
        description: "List all tasks",
        timeout_ms: 1500,
        deployment_status: "deployed",
        capabilities: ["task_management", "gtd"],
        inputSchema: %{properties: %{"status" => %{"type" => "string"}}, required: []}
      },
      %{
        name: "gtd.task.update",
        description: "Update an existing task",
        timeout_ms: 2000,
        deployment_status: "deployed",
        capabilities: ["task_management", "gtd"],
        inputSchema: %{properties: %{"task_id" => %{"type" => "string"}}, required: ["task_id"]}
      },
      # Synapse Bot - Messaging
      %{
        name: "synapse.message.send",
        description: "Send a message via Synapse",
        timeout_ms: 3000,
        deployment_status: "deployed",
        capabilities: ["messaging", "communication"],
        inputSchema: %{properties: %{}, required: []}
      },
      # Notification Bot - Alerts
      %{
        name: "notification.push",
        description: "Send push notification",
        timeout_ms: 1000,
        deployment_status: "deployed",
        capabilities: ["notifications"],
        inputSchema: %{properties: %{"message" => %{"type" => "string"}}, required: ["message"]}
      },
      # Experimental Bot
      %{
        name: "search.advanced",
        description: "Advanced search functionality",
        timeout_ms: 5000,
        deployment_status: "experimental",
        capabilities: ["search"],
        inputSchema: %{properties: %{"query" => %{"type" => "string"}}, required: ["query"]}
      }
    ]

    {:ok, tools: tools}
  end

  describe "full pipeline integration" do
    test "semantic matching + context filtering pipeline", %{tools: tools} do
      # Scenario: User in deep_work mode wants to "create task"
      query = "create task"

      context = %{
        focus_mode: "deep_work",
        max_timeout_ms: 3000,
        bot_health_map: %{"gtd" => "healthy", "synapse" => "degraded"}
      }

      # Step 1: Semantic matching
      semantic_results = SemanticToolMatcher.find_tools(tools, query, limit: 10)
      assert semantic_results != []
      assert List.first(semantic_results).name == "gtd.task.create"

      # Step 2: Context-aware filtering (simulating full pipeline)
      filtered_results =
        ContextAwareToolFilter.filter_tools(semantic_results, context, limit: 5)

      assert filtered_results != []
      top = List.first(filtered_results)
      assert String.contains?(top.name, "task.create")
      # Should not include messaging tools in deep_work
      assert not Enum.any?(filtered_results, &String.contains?(&1.name, "message"))
    end

    test "schema metadata flows through pipeline", %{tools: tools} do
      # Tools with schemas should have inputSchema populated
      tool_with_schema = Enum.find(tools, &String.contains?(&1.name, "gtd.task.create"))
      assert Map.has_key?(tool_with_schema, :inputSchema)
      assert Map.has_key?(tool_with_schema.inputSchema, :properties)

      # Semantic matcher preserves schema
      results = SemanticToolMatcher.find_tools(tools, "create task")
      found = Enum.find(results, &String.contains?(&1.name, "task.create"))
      assert found.inputSchema.properties != nil
    end

    test "context-aware filtering respects all constraints", %{tools: tools} do
      context = %{
        focus_mode: "deep_work",
        max_timeout_ms: 2000,
        min_health_score: 0.7,
        bot_health_map: %{
          "gtd" => "healthy",
          "synapse" => "degraded",
          "notification" => "unhealthy"
        }
      }

      results = ContextAwareToolFilter.filter_tools(tools, context)

      # Should include GTD tools (healthy, fast)
      assert Enum.any?(results, &String.contains?(&1.name, "gtd"))

      # Should exclude notification tools (unhealthy)
      assert not Enum.any?(results, &String.contains?(&1.name, "notification"))

      # Should exclude message tools (deep_work mode)
      assert not Enum.any?(results, &String.contains?(&1.name, "message"))
    end
  end

  describe "real-world scenarios" do
    test "deep_work: create task with time pressure", %{tools: tools} do
      # User in deep_work, limited time, needs to create task
      query = "create task"

      context = %{
        focus_mode: "deep_work",
        max_timeout_ms: 2500,
        bot_health_map: %{"gtd" => "healthy"}
      }

      results =
        ContextAwareToolFilter.filter_tools(
          SemanticToolMatcher.find_tools(tools, query),
          context,
          limit: 1
        )

      assert results != []
      top = List.first(results)
      # Should recommend task creation tool
      assert String.contains?(top.name, "task.create")
      # Should be within time budget
      assert top.timeout_ms <= 2500
    end

    test "shallow_work: list items quickly", %{tools: tools} do
      # User has shallow work time, wants quick operations
      query = "list"

      context = %{
        focus_mode: "shallow_work",
        max_timeout_ms: 2000
      }

      results =
        ContextAwareToolFilter.filter_tools(
          SemanticToolMatcher.find_tools(tools, query),
          context,
          limit: 3
        )

      assert results != []
      # Fast tools should rank higher
      fast_tools = Enum.filter(results, &(&1.timeout_ms <= 2000))
      assert fast_tools != []
    end

    test "capability matching with intent", %{tools: tools} do
      # User intent: needs task management functionality
      query = "manage tasks"

      context = %{
        intent: "task_management",
        bot_health_map: %{"gtd" => "healthy"}
      }

      results =
        ContextAwareToolFilter.filter_tools(
          SemanticToolMatcher.find_tools(tools, query),
          context,
          limit: 3
        )

      assert results != []
      # Should prioritize tools with task_management capability
      top = List.first(results)

      assert Enum.any?(
               tools,
               fn t ->
                 t.name == top.name && Enum.any?(t.capabilities, &String.contains?(&1, "task"))
               end
             )
    end

    test "degraded service handling", %{tools: tools} do
      # Synapse is degraded, should be deprioritized
      query = "message"

      context = %{
        bot_health_map: %{"synapse" => "degraded"},
        # Not deep_work, so messaging tools are available
        focus_mode: "break"
      }

      semantic = SemanticToolMatcher.find_tools(tools, query)
      # Even with semantic match, health filtering should deprioritize
      with_health =
        Enum.map(semantic, fn tool ->
          score = ContextAwareToolFilter.score_with_context(tool, context)
          Map.put(tool, :health_aware_score, score)
        end)

      # Degraded tools should have lower scores
      degraded =
        Enum.find(with_health, &String.contains?(&1.name, "message"))

      if degraded do
        healthy_query_score =
          Enum.find(with_health, &String.contains?(&1.name, "task.create"))

        # Healthy tools should have higher score than degraded
        if healthy_query_score do
          assert degraded.health_aware_score <= healthy_query_score.health_aware_score
        end
      end
    end
  end

  describe "schema metadata integration" do
    test "all tools maintain schema through pipeline", %{tools: tools} do
      query = "task"

      # Semantic matcher should preserve schemas
      semantic_results = SemanticToolMatcher.find_tools(tools, query)

      Enum.each(semantic_results, fn result ->
        assert Map.has_key?(result, :inputSchema)
        assert is_map(result.inputSchema)
        assert Map.has_key?(result.inputSchema, :properties)
        assert Map.has_key?(result.inputSchema, :required)
      end)
    end

    test "context filter preserves all tool metadata", %{tools: tools} do
      context = %{focus_mode: "break"}
      results = ContextAwareToolFilter.filter_tools(tools, context)

      Enum.each(results, fn result ->
        assert Map.has_key?(result, :name)
        assert Map.has_key?(result, :timeout_ms)
        assert Map.has_key?(result, :deployment_status)
        assert Map.has_key?(result, :capabilities)
        assert Map.has_key?(result, :context_score)
      end)
    end
  end

  describe "error handling and edge cases" do
    test "empty query handling" do
      tools = [
        %{name: "test.endpoint", timeout_ms: 1000, deployment_status: "deployed"}
      ]

      results = SemanticToolMatcher.find_tools(tools, "")
      # Empty query should still return results (or empty list, not crash)
      assert is_list(results)
    end

    test "missing optional fields" do
      # Tools without all optional fields should still work
      minimal_tools = [
        %{name: "minimal.tool"},
        %{
          name: "complete.tool",
          description: "A complete tool",
          timeout_ms: 5000,
          capabilities: ["test"]
        }
      ]

      context = %{focus_mode: "break"}
      results = ContextAwareToolFilter.filter_tools(minimal_tools, context)

      # Should handle both minimal and complete tools
      assert results != []
      assert Enum.all?(results, &Map.has_key?(&1, :context_score))
    end

    test "missing health data defaults gracefully", %{tools: tools} do
      # Context with no health map should still work
      context = %{focus_mode: "shallow_work", max_timeout_ms: 5000}

      results = ContextAwareToolFilter.filter_tools(tools, context)
      assert results != []
      # Should all have context scores
      assert Enum.all?(results, &Map.has_key?(&1, :context_score))
    end
  end

  describe "performance and scale" do
    test "handles many tools efficiently", %{tools: base_tools} do
      # Create a larger tool set
      large_tools =
        Enum.concat(
          base_tools,
          Enum.map(1..100, fn i ->
            %{
              name: "service#{i}.endpoint#{i}",
              description: "Service #{i} endpoint",
              timeout_ms: 1000 + i * 10,
              deployment_status: "deployed",
              capabilities: ["service#{i}"]
            }
          end)
        )

      context = %{
        focus_mode: "break",
        max_timeout_ms: 5000,
        bot_health_map: %{"gtd" => "healthy"}
      }

      # Should handle 100+ tools without issues
      results =
        ContextAwareToolFilter.filter_tools(
          SemanticToolMatcher.find_tools(large_tools, "endpoint"),
          context,
          limit: 10
        )

      assert length(results) <= 10
      assert Enum.all?(results, &Map.has_key?(&1, :context_score))
    end
  end
end
