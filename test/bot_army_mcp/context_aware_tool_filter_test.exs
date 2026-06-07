defmodule BotArmyMcp.ContextAwareToolFilterTest do
  use ExUnit.Case
  doctest BotArmyMcp.ContextAwareToolFilter

  alias BotArmyMcp.ContextAwareToolFilter

  setup do
    # Standard test tools with health and capability metadata
    tools = [
      %{
        name: "gtd.task.create",
        description: "Create a task",
        timeout_ms: 2000,
        deployment_status: "deployed",
        capabilities: ["task_management", "gtd"]
      },
      %{
        name: "gtd.task.list",
        description: "List tasks",
        timeout_ms: 1500,
        deployment_status: "deployed",
        capabilities: ["task_management", "gtd"]
      },
      %{
        name: "gtd.task.update",
        description: "Update a task",
        timeout_ms: 2000,
        deployment_status: "deployed",
        capabilities: ["task_management", "gtd"]
      },
      %{
        name: "synapse.message.send",
        description: "Send a message",
        timeout_ms: 3000,
        deployment_status: "deployed",
        capabilities: ["messaging", "communication"]
      },
      %{
        name: "notification.alert.send",
        description: "Send an alert notification",
        timeout_ms: 1000,
        deployment_status: "experimental",
        capabilities: ["notifications"]
      },
      %{
        name: "archive.search",
        description: "Search archived items",
        timeout_ms: 5000,
        deployment_status: "archived",
        capabilities: ["search"]
      }
    ]

    {:ok, tools: tools}
  end

  describe "filter_tools/3" do
    test "returns empty list for empty tools" do
      result = ContextAwareToolFilter.filter_tools([], %{})
      assert result == []
    end

    test "filters out archived and disabled tools", %{tools: tools} do
      result = ContextAwareToolFilter.filter_tools(tools, %{})
      names = Enum.map(result, & &1.name)

      assert not Enum.any?(names, &String.contains?(&1, "archive"))
    end

    test "filters by focus mode (deep_work)", %{tools: tools} do
      context = %{focus_mode: "deep_work"}
      result = ContextAwareToolFilter.filter_tools(tools, context)
      names = Enum.map(result, & &1.name)

      # Messaging and notification tools should be filtered out
      assert not Enum.any?(names, &String.contains?(&1, "message"))
      assert not Enum.any?(names, &String.contains?(&1, "notification"))
    end

    test "keeps all tools in shallow_work and break modes", %{tools: tools} do
      for focus_mode <- ["shallow_work", "break"] do
        context = %{focus_mode: focus_mode}
        result = ContextAwareToolFilter.filter_tools(tools, context)

        # Should include messaging tools (unless archived)
        assert Enum.any?(result, &String.contains?(&1.name, "message"))
      end
    end

    test "respects max_timeout_ms constraint", %{tools: tools} do
      # Set max to 2000ms - should deprioritize tools with longer timeouts
      context = %{max_timeout_ms: 2000}
      result = ContextAwareToolFilter.filter_tools(tools, context)

      # Tools under timeout should have higher scores
      fast_tools = Enum.filter(result, fn t -> Map.get(t, :timeout_ms, 5000) <= 2000 end)
      assert fast_tools != []
    end

    test "respects min_health_score", %{tools: tools} do
      # Mark some tools as unhealthy
      bot_health_map = %{
        "synapse" => "unhealthy",
        "notification" => "degraded",
        "archive" => "unhealthy"
      }

      context = %{
        min_health_score: 0.7,
        bot_health_map: bot_health_map
      }

      result = ContextAwareToolFilter.filter_tools(tools, context)
      names = Enum.map(result, & &1.name)

      # Unhealthy tools should be filtered out
      assert not Enum.any?(names, &String.contains?(&1, "synapse"))
    end

    test "respects limit option", %{tools: tools} do
      result = ContextAwareToolFilter.filter_tools(tools, %{}, limit: 2)
      assert length(result) <= 2
    end

    test "respects require_deployed option", %{tools: tools} do
      result = ContextAwareToolFilter.filter_tools(tools, %{}, require_deployed: true)
      names = Enum.map(result, & &1.name)

      # Only deployed tools should be returned
      assert Enum.all?(result, &(Map.get(&1, :deployment_status) == "deployed"))
      # Experimental tools should be excluded
      assert not Enum.any?(names, &String.contains?(&1, "notification"))
    end

    test "adds context_score field to results", %{tools: tools} do
      result = ContextAwareToolFilter.filter_tools(tools, %{})
      assert result != []

      Enum.each(result, fn tool ->
        assert Map.has_key?(tool, :context_score)
        assert is_float(tool.context_score) or is_integer(tool.context_score)
      end)
    end

    test "returns tools sorted by context_score descending", %{tools: tools} do
      result = ContextAwareToolFilter.filter_tools(tools, %{})
      scores = Enum.map(result, & &1.context_score)

      assert scores == Enum.sort(scores, :desc)
    end
  end

  describe "score_with_context/2" do
    test "scores healthy tools higher than degraded" do
      healthy_tool = %{
        name: "gtd.task.create",
        timeout_ms: 2000,
        deployment_status: "deployed"
      }

      degraded_tool = %{
        name: "synapse.message.send",
        timeout_ms: 2000,
        deployment_status: "deployed"
      }

      context = %{
        bot_health_map: %{
          "gtd" => "healthy",
          "synapse" => "degraded"
        }
      }

      score_healthy = ContextAwareToolFilter.score_with_context(healthy_tool, context)
      score_degraded = ContextAwareToolFilter.score_with_context(degraded_tool, context)

      assert is_float(score_healthy) or is_integer(score_healthy)
      assert is_float(score_degraded) or is_integer(score_degraded)
      assert score_healthy > score_degraded
    end

    test "scores tools matching context intent higher" do
      tool = %{
        name: "gtd.task.create",
        timeout_ms: 2000,
        capabilities: ["task_management", "gtd"]
      }

      # Intent matches capabilities
      context_match = %{intent: "task management"}
      score_match = ContextAwareToolFilter.score_with_context(tool, context_match)

      # Intent doesn't match
      context_nomatch = %{intent: "messaging"}
      score_nomatch = ContextAwareToolFilter.score_with_context(tool, context_nomatch)

      assert score_match >= score_nomatch
    end

    test "scores tools with suitable timeouts higher" do
      tool = %{
        name: "gtd.task.create",
        timeout_ms: 2000,
        deployment_status: "deployed"
      }

      # Max timeout is higher than tool timeout
      context_suitable = %{max_timeout_ms: 5000}
      score_suitable = ContextAwareToolFilter.score_with_context(tool, context_suitable)

      # Max timeout is lower than tool timeout
      context_unsuitable = %{max_timeout_ms: 1000}
      score_unsuitable = ContextAwareToolFilter.score_with_context(tool, context_unsuitable)

      assert score_suitable > score_unsuitable
    end

    test "handles missing context gracefully" do
      tool = %{
        name: "gtd.task.create",
        timeout_ms: 2000
      }

      score = ContextAwareToolFilter.score_with_context(tool, %{})
      assert score >= 0.0
    end

    test "handles missing tool fields gracefully" do
      tool = %{name: "gtd.task.create"}

      context = %{
        max_timeout_ms: 5000,
        intent: "task"
      }

      score = ContextAwareToolFilter.score_with_context(tool, context)
      assert score >= 0.0
    end
  end

  describe "health scoring" do
    test "healthy tools score 1.0" do
      tool = %{name: "gtd.task.create"}
      context = %{bot_health_map: %{"gtd" => "healthy"}}

      # Health score contributes 0.3 to total, so with 1.0 health it adds 0.3
      score = ContextAwareToolFilter.score_with_context(tool, context)
      assert score >= 0.3
    end

    test "degraded tools score 0.7" do
      tool = %{name: "gtd.task.create"}
      context = %{bot_health_map: %{"gtd" => "degraded"}}

      # Health score of 0.7 contributes 0.21 to total
      score = ContextAwareToolFilter.score_with_context(tool, context)
      assert score >= 0.2
    end

    test "unhealthy tools score 0.0 for health" do
      tool = %{name: "gtd.task.create"}
      context = %{bot_health_map: %{"gtd" => "unhealthy"}}

      score = ContextAwareToolFilter.score_with_context(tool, context)
      # Can still have some score from timeout/capability, but health is 0
      assert score < 0.5
    end
  end

  describe "timeout scoring" do
    test "tools within timeout are scored 1.0" do
      tool = %{name: "gtd.task.create", timeout_ms: 2000}
      context = %{max_timeout_ms: 5000}

      score = ContextAwareToolFilter.score_with_context(tool, context)
      # Timeout contributes 0.2 at 1.0, so should be visible
      assert score >= 0.2
    end

    test "tools slightly over timeout are scored 0.8" do
      tool = %{name: "gtd.task.create", timeout_ms: 7000}
      context = %{max_timeout_ms: 5000}

      score = ContextAwareToolFilter.score_with_context(tool, context)
      # 0.8 * 0.2 = 0.16
      assert score >= 0.1
    end

    test "tools far over timeout are scored lower" do
      tool = %{name: "gtd.task.create", timeout_ms: 20000}
      context = %{max_timeout_ms: 5000}

      score = ContextAwareToolFilter.score_with_context(tool, context)
      # Timeout is 4x max, scores 0.2 (0.04 contribution)
      # But default health and capability still contribute
      # Total: health(1.0*0.3) + timeout(0.2*0.2) + capability(0.5*0.5) = 0.59
      # Score should be lower than tools with suitable timeout
      suitable_score = ContextAwareToolFilter.score_with_context(tool, %{max_timeout_ms: 30000})
      assert score < suitable_score
    end
  end

  describe "capability matching" do
    test "tools with matching capabilities score higher" do
      tool = %{
        name: "gtd.task.create",
        capabilities: ["task_management"]
      }

      context_match = %{intent: "task_management"}
      score_match = ContextAwareToolFilter.score_with_context(tool, context_match)

      context_nomatch = %{intent: "messaging"}
      score_nomatch = ContextAwareToolFilter.score_with_context(tool, context_nomatch)

      assert score_match > score_nomatch
    end

    test "tools without capabilities get neutral score" do
      tool = %{name: "generic.endpoint"}
      context = %{intent: "something"}

      score = ContextAwareToolFilter.score_with_context(tool, context)
      # Should still have some score, but not high
      assert score >= 0.0
    end
  end

  describe "real-world scenarios" do
    test "deep_work context removes messaging tools" do
      tools = [
        %{name: "gtd.task.create", timeout_ms: 2000, deployment_status: "deployed"},
        %{name: "synapse.message.send", timeout_ms: 3000, deployment_status: "deployed"},
        %{name: "notification.push", timeout_ms: 1000, deployment_status: "deployed"}
      ]

      context = %{focus_mode: "deep_work"}
      result = ContextAwareToolFilter.filter_tools(tools, context)
      names = Enum.map(result, & &1.name)

      assert Enum.any?(names, &String.contains?(&1, "task.create"))
      assert not Enum.any?(names, &String.contains?(&1, "message"))
      assert not Enum.any?(names, &String.contains?(&1, "notification"))
    end

    test "shallow_work with low time budget prefers fast tools" do
      tools = [
        %{name: "gtd.task.list", timeout_ms: 1000, deployment_status: "deployed"},
        %{name: "search.deep", timeout_ms: 10000, deployment_status: "deployed"}
      ]

      context = %{focus_mode: "shallow_work", max_timeout_ms: 2000}
      result = ContextAwareToolFilter.filter_tools(tools, context)

      # Fast tool should score higher
      first_tool = List.first(result)
      assert Map.get(first_tool, :timeout_ms) <= 2000
    end

    test "capability matching for specific intent" do
      tools = [
        %{
          name: "gtd.task.create",
          timeout_ms: 2000,
          deployment_status: "deployed",
          capabilities: ["task_management"]
        },
        %{
          name: "synapse.message.send",
          timeout_ms: 3000,
          deployment_status: "deployed",
          capabilities: ["messaging"]
        }
      ]

      context = %{intent: "create task"}
      result = ContextAwareToolFilter.filter_tools(tools, context, limit: 1)

      # Task creation tool should rank first
      top = List.first(result)
      assert String.contains?(top.name, "task.create")
    end
  end
end
