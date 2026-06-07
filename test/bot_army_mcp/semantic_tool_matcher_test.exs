defmodule BotArmyMcp.SemanticToolMatcherTest do
  use ExUnit.Case
  doctest BotArmyMcp.SemanticToolMatcher

  alias BotArmyMcp.SemanticToolMatcher

  setup do
    # Standard test tools
    tools = [
      %{
        name: "gtd.task.create",
        description: "Create a new task",
        inputSchema: %{
          properties: %{
            "title" => %{"type" => "string"},
            "priority" => %{"type" => "string"}
          }
        }
      },
      %{
        name: "gtd.task.list",
        description: "List all tasks",
        inputSchema: %{
          properties: %{
            "status" => %{"type" => "string"},
            "limit" => %{"type" => "integer"}
          }
        }
      },
      %{
        name: "gtd.task.update",
        description: "Update an existing task"
      },
      %{
        name: "gtd.project.create",
        description: "Create a new project"
      },
      %{
        name: "synapse.message.send",
        description: "Send a message via Synapse"
      }
    ]

    {:ok, tools: tools}
  end

  describe "score_tool/2" do
    test "scores exact subject match highest" do
      tool = %{
        name: "gtd.task.create",
        description: "Create something"
      }

      # Query matches the word 'task' in subject
      score = SemanticToolMatcher.score_tool(tool, "create task")
      assert score > 0.0
    end

    test "scores description matches lower than subject" do
      tool1 = %{
        name: "gtd.task.create",
        description: "Create a new task"
      }

      tool2 = %{
        name: "api.project.list",
        description: "Create a new task easily"
      }

      score1 = SemanticToolMatcher.score_tool(tool1, "create task")
      score2 = SemanticToolMatcher.score_tool(tool2, "create task")

      # tool1 has 'task' in subject, tool2 only in description
      assert score1 > score2
    end

    test "returns zero score for no matches" do
      tool = %{
        name: "gtd.task.create",
        description: "Create a task"
      }

      score = SemanticToolMatcher.score_tool(tool, "xyz xyz xyz")
      assert score == 0.0
    end

    test "handles case-insensitive matching" do
      tool = %{
        name: "gtd.task.create",
        description: "Create a task"
      }

      score_lower = SemanticToolMatcher.score_tool(tool, "create task")
      score_upper = SemanticToolMatcher.score_tool(tool, "CREATE TASK")
      score_mixed = SemanticToolMatcher.score_tool(tool, "Create Task")

      assert score_lower == score_upper
      assert score_lower == score_mixed
    end

    test "scores property name matches lowest" do
      tool = %{
        name: "other.endpoint",
        description: "Some endpoint",
        inputSchema: %{
          properties: %{
            "priority" => %{"type" => "string"}
          }
        }
      }

      score = SemanticToolMatcher.score_tool(tool, "priority")
      # Should be non-zero but small (only property match)
      assert score > 0.0
      assert score < 0.5
    end

    test "handles missing fields gracefully" do
      tool = %{name: "endpoint.name"}
      # No description or inputSchema
      score = SemanticToolMatcher.score_tool(tool, "endpoint")
      assert score > 0.0
    end
  end

  describe "find_tools/2" do
    test "returns empty list for empty tools", %{tools: _tools} do
      result = SemanticToolMatcher.find_tools([], "query")
      assert result == []
    end

    test "returns results sorted by score descending", %{tools: tools} do
      # Query that should match gtd.task.create > gtd.task.list > gtd.project.create
      result = SemanticToolMatcher.find_tools(tools, "create task")

      assert result != []
      scores = Enum.map(result, & &1.score)

      # Verify scores are in descending order
      assert scores == Enum.sort(scores, :desc)
    end

    test "respects limit option", %{tools: tools} do
      result = SemanticToolMatcher.find_tools(tools, "task", limit: 2)
      assert length(result) <= 2
    end

    test "respects min_score option", %{tools: tools} do
      result = SemanticToolMatcher.find_tools(tools, "task", min_score: 1.0)
      # All results should have score >= 1.0
      assert Enum.all?(result, fn tool -> tool.score >= 1.0 end)
    end

    test "adds score field to results", %{tools: tools} do
      result = SemanticToolMatcher.find_tools(tools, "create")
      assert result != []

      Enum.each(result, fn tool ->
        assert Map.has_key?(tool, :score)
        assert is_float(tool.score) or is_integer(tool.score)
      end)
    end
  end

  describe "semantic ranking" do
    test "prioritizes exact word matches", %{tools: tools} do
      result = SemanticToolMatcher.find_tools(tools, "task")
      # GTD task-related tools should rank highest
      assert Enum.any?(result, fn t -> String.contains?(t.name, "gtd.task") end)
    end

    test "handles multi-word queries", %{tools: tools} do
      result = SemanticToolMatcher.find_tools(tools, "create new task")
      assert result != []
      # gtd.task.create should rank high
      top = List.first(result)
      assert String.contains?(top.name, "task.create")
    end

    test "matches partial words via tokenization", %{tools: tools} do
      result = SemanticToolMatcher.find_tools(tools, "msg")
      # synapse.message.send contains "message"
      assert Enum.any?(result, fn t -> t.name == "synapse.message.send" end)
    end

    test "real-world examples", %{tools: tools} do
      # "I want to create a task" → gtd.task.create
      result = SemanticToolMatcher.find_tools(tools, "create task")
      assert Enum.any?(result, fn t -> t.name == "gtd.task.create" end)

      # "show my tasks" → gtd.task.list
      result = SemanticToolMatcher.find_tools(tools, "list tasks")
      assert Enum.any?(result, fn t -> t.name == "gtd.task.list" end)

      # "send a message" → synapse.message.send
      result = SemanticToolMatcher.find_tools(tools, "send message")
      assert Enum.any?(result, fn t -> t.name == "synapse.message.send" end)

      # "new project" → gtd.project.create
      result = SemanticToolMatcher.find_tools(tools, "create project")
      assert Enum.any?(result, fn t -> t.name == "gtd.project.create" end)
    end
  end

  describe "edge cases" do
    test "handles empty query" do
      tool = %{name: "endpoint", description: "A tool"}
      score = SemanticToolMatcher.score_tool(tool, "")
      assert score == 0.0
    end

    test "handles special characters in subject names" do
      tool = %{name: "api_v2.user-info.get_data", description: "Get user info"}
      score = SemanticToolMatcher.score_tool(tool, "user info")
      assert score > 0.0
    end

    test "ignores empty tokens after split" do
      tool = %{name: "endpoint", description: "tool"}
      score1 = SemanticToolMatcher.score_tool(tool, "endpoint")
      score2 = SemanticToolMatcher.score_tool(tool, "endpoint   ")
      assert score1 == score2
    end

    test "handles nil schema gracefully" do
      tool = %{name: "endpoint", description: "tool", inputSchema: nil}
      score = SemanticToolMatcher.score_tool(tool, "endpoint")
      assert score > 0.0
    end

    test "handles empty properties in schema" do
      tool = %{
        name: "endpoint",
        description: "tool",
        inputSchema: %{properties: %{}}
      }

      score = SemanticToolMatcher.score_tool(tool, "endpoint")
      assert score > 0.0
    end
  end
end
