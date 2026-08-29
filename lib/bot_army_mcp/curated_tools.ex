defmodule BotArmyMcp.CuratedTools do
  @moduledoc """
  Definitions for curated, first-class MCP tools that front the Bot Army Bridge.

  In `:curated` tools mode (the default) these are the only tools exposed to MCP
  clients such as Claude Desktop. The set is deliberately small (~15 high-value
  tools) so a client is not flooded with the full fleet subject surface.
  """

  @curated_tools %{
    "bridge_chat" => %{
      subject: "bridge.chat",
      description:
        "Send a message to the Bot Army bridge for general interaction and coordination (LLM-backed).",
      inputSchema: %{
        type: "object",
        properties: %{"message" => %{type: "string"}},
        required: ["message"]
      },
      timeout_ms: 55000
    },
    "bridge_task_list" => %{
      subject: "bridge.task.list",
      description: "List current GTD tasks (supports pagination and filters).",
      inputSchema: %{
        type: "object",
        properties: %{
          "limit" => %{type: "integer", description: "Max tasks to return"},
          "offset" => %{type: "integer", description: "Tasks to skip"},
          "status" => %{type: "string", description: "Filter by status (e.g. active)"},
          "context" => %{type: "string", description: "Filter by context"},
          "labels" => %{type: "array", items: %{type: "string"}, description: "Filter by labels"}
        },
        required: []
      },
      timeout_ms: 8000
    },
    "bridge_task_search" => %{
      subject: "bridge.task.search",
      description:
        "Search for tasks using queries and filters (e.g., searching for tasks with no project).",
      inputSchema: %{
        type: "object",
        properties: %{
          "query" => %{type: "string", description: "Search query"},
          "filters" => %{
            type: "object",
            properties: %{
              "no_project" => %{
                type: "boolean",
                description: "Filter for tasks without a project"
              }
            }
          }
        },
        required: []
      },
      timeout_ms: 8000
    },
    "bridge_task_create" => %{
      subject: "bridge.task.create",
      description: "Create a new GTD task.",
      inputSchema: %{
        type: "object",
        properties: %{
          "title" => %{type: "string", description: "Task title"},
          "description" => %{type: "string", description: "Task description (acceptance criteria encouraged)"},
          "project_id" => %{type: "string", description: "Parent project ID"},
          "labels" => %{type: "array", items: %{type: "string"}, description: "Routing/scope labels"},
          "assignee" => %{type: "string", description: "Assignee"}
        },
        required: ["title"]
      },
      timeout_ms: 8000
    },
    "bridge_task_complete" => %{
      subject: "bridge.task.complete",
      description: "Mark a GTD task complete (may return an undo token).",
      inputSchema: %{
        type: "object",
        properties: %{"task_id" => %{type: "string", description: "Task ID (UUID)"}},
        required: ["task_id"]
      },
      timeout_ms: 8000
    },
    "bridge_project_list" => %{
      subject: "bridge.project.list",
      description: "List all projects in the GTD system.",
      inputSchema: %{type: "object", properties: %{}, required: []},
      timeout_ms: 8000
    },
    "bridge_inbox_list" => %{
      subject: "bridge.inbox.list",
      description: "List inbox messages.",
      inputSchema: %{
        type: "object",
        properties: %{
          "limit" => %{type: "integer", description: "Max messages"},
          "status" => %{type: "string", description: "Filter by status"}
        },
        required: []
      },
      timeout_ms: 8000
    },
    "bridge_inbox_capture" => %{
      subject: "bridge.inbox.capture",
      description: "Capture a quick idea or task to the inbox.",
      inputSchema: %{
        type: "object",
        properties: %{"content" => %{type: "string", description: "Raw capture text"}},
        required: ["content"]
      },
      timeout_ms: 8000
    },
    "bridge_para_query" => %{
      subject: "bridge.para.query",
      description: "Search the PARA knowledge base.",
      inputSchema: %{
        type: "object",
        properties: %{"query" => %{type: "string", description: "Search query"}},
        required: ["query"]
      },
      timeout_ms: 15000
    },
    "bridge_para_fs_read" => %{
      subject: "bridge.para.fs.read",
      description: "Read a file from PARA.",
      inputSchema: %{
        type: "object",
        properties: %{"relative_path" => %{type: "string", description: "Path inside PARA root"}},
        required: ["relative_path"]
      },
      timeout_ms: 8000
    },
    "bridge_para_fs_write" => %{
      subject: "bridge.para.fs.write",
      description: "Write or append to a PARA file.",
      inputSchema: %{
        type: "object",
        properties: %{
          "relative_path" => %{type: "string", description: "Path inside PARA root"},
          "content" => %{type: "string"},
          "mode" => %{type: "string", description: "\"write\" or \"append\""}
        },
        required: ["relative_path", "content"]
      },
      timeout_ms: 8000
    },
    "bridge_energy_log" => %{
      subject: "bridge.energy.log",
      description: "Log current energy level (1-10).",
      inputSchema: %{
        type: "object",
        properties: %{"level" => %{type: "integer", minimum: 1, maximum: 10}},
        required: ["level"]
      },
      timeout_ms: 5000
    },
    "bridge_habits_status" => %{
      subject: "bridge.habits.status",
      description: "Check habit status and streaks.",
      inputSchema: %{type: "object", properties: %{}, required: []},
      timeout_ms: 8000
    },
    "bridge_timer_status" => %{
      subject: "bridge.timer.status",
      description: "Get current timer status.",
      inputSchema: %{type: "object", properties: %{}, required: []},
      timeout_ms: 5000
    },
    "bridge_daily_brief" => %{
      subject: "bridge.daily.brief",
      description: "Get today's brief and priorities.",
      inputSchema: %{type: "object", properties: %{}, required: []},
      timeout_ms: 15000
    },
    "bridge_self_health_status" => %{
      subject: "bridge.self_health.status",
      description: "Check Bot Army self-health status.",
      inputSchema: %{type: "object", properties: %{}, required: []},
      timeout_ms: 8000
    }
  }

  def all do
    Map.new(@curated_tools, fn {name, def} ->
      {name,
       %{
         name: name,
         description: def.description,
         inputSchema: def.inputSchema,
         timeout_ms: def.timeout_ms
       }}
    end)
  end

  def resolve_subject(mcp_name) do
    case Map.get(@curated_tools, mcp_name) do
      nil -> mcp_name
      tool -> tool.subject
    end
  end

  def subject_curated?(subject) do
    Enum.any?(@curated_tools, fn {_, def} -> def.subject == subject end)
  end

  def names do
    Map.keys(@curated_tools)
  end

  def timeout_ms(mcp_name, default \\ 5000) do
    case Map.get(@curated_tools, mcp_name) do
      nil -> default
      tool -> tool.timeout_ms
    end
  end
end
