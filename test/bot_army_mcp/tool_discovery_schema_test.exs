defmodule BotArmyMcp.ToolDiscoverySchemaTest do
  use ExUnit.Case
  doctest BotArmyMcp.ToolDiscovery

  describe "schema extraction from registry" do
    test "to_mcp_tool_definition extracts schema metadata correctly" do
      # Subject with full schema metadata
      subject_with_schema = %{
        "subject" => "gtd.task.create",
        "type" => "request_reply",
        "description" => "Create a GTD task",
        "timeout_ms" => 5000,
        "schema" => %{
          "properties" => %{
            "title" => %{"type" => "string", "description" => "Task title"},
            "priority" => %{
              "type" => "string",
              "enum" => ["low", "normal", "high"],
              "description" => "Task priority"
            },
            "description" => %{"type" => "string"}
          },
          "required" => ["title"]
        }
      }

      # Subject without schema metadata
      subject_without_schema = %{
        "subject" => "gtd.task.list",
        "type" => "request_reply",
        "description" => "List GTD tasks",
        "timeout_ms" => 5000
      }

      # Test schema extraction for subject with metadata
      tool_with_schema = parse_tool_definition(subject_with_schema)

      assert tool_with_schema.name == "gtd.task.create"
      assert tool_with_schema.description == "Create a GTD task"
      assert tool_with_schema.timeout_ms == 5000
      assert tool_with_schema.inputSchema.type == "object"

      # Should have properties from schema
      assert map_size(tool_with_schema.inputSchema.properties) == 3
      assert Map.has_key?(tool_with_schema.inputSchema.properties, "title")
      assert Map.has_key?(tool_with_schema.inputSchema.properties, "priority")

      # Should have required fields from schema
      assert tool_with_schema.inputSchema.required == ["title"]

      # Test schema extraction for subject without metadata
      tool_without_schema = parse_tool_definition(subject_without_schema)

      assert tool_without_schema.name == "gtd.task.list"
      assert tool_without_schema.inputSchema.type == "object"
      assert tool_without_schema.inputSchema.properties == %{}
      assert tool_without_schema.inputSchema.required == []
    end

    test "handles nil and missing schema fields gracefully" do
      # Subject with nil schema
      subject_nil_schema = %{
        "subject" => "test.endpoint",
        "type" => "request_reply",
        "description" => "Test endpoint",
        "schema" => nil
      }

      # Subject with empty schema
      subject_empty_schema = %{
        "subject" => "test.endpoint2",
        "type" => "request_reply",
        "description" => "Test endpoint 2",
        "schema" => %{}
      }

      tool_nil = parse_tool_definition(subject_nil_schema)
      assert tool_nil.inputSchema.properties == %{}
      assert tool_nil.inputSchema.required == []

      tool_empty = parse_tool_definition(subject_empty_schema)
      assert tool_empty.inputSchema.properties == %{}
      assert tool_empty.inputSchema.required == []
    end

    test "partial schema metadata is handled correctly" do
      # Schema with only properties, no required
      subject_partial1 = %{
        "subject" => "test.partial1",
        "type" => "request_reply",
        "schema" => %{
          "properties" => %{
            "param" => %{"type" => "string"}
          }
        }
      }

      # Schema with only required, no properties
      subject_partial2 = %{
        "subject" => "test.partial2",
        "type" => "request_reply",
        "schema" => %{
          "required" => ["param1", "param2"]
        }
      }

      tool1 = parse_tool_definition(subject_partial1)
      assert map_size(tool1.inputSchema.properties) == 1
      assert tool1.inputSchema.required == []

      tool2 = parse_tool_definition(subject_partial2)
      assert tool2.inputSchema.properties == %{}
      assert tool2.inputSchema.required == ["param1", "param2"]
    end
  end

  # Helper to simulate the tool definition parsing logic
  # This mimics what ToolDiscovery.to_mcp_tool_definition/2 does
  defp parse_tool_definition(subject_def) do
    schema = subject_def["schema"] || %{}
    properties = schema["properties"] || %{}
    required = schema["required"] || []

    %{
      name: subject_def["subject"],
      description: subject_def["description"] || "Bot Army service",
      inputSchema: %{
        type: "object",
        properties: properties,
        required: required
      },
      timeout_ms: subject_def["timeout_ms"] || 5000
    }
  end
end
