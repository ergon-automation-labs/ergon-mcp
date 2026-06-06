defmodule BotArmyMcp.ToolDiscovery do
  @moduledoc """
  Discovers Bot Army capabilities and exposes them as MCP tools.

  Queries bot_army.registry.bots.list to fetch all registered bots and their
  subjects. Filters for request_reply subjects (callable tools) and maps them
  to MCP tool definitions with input schemas.

  Caches results with TTL to avoid hammering the registry.
  """

  use GenServer
  require Logger

  alias BotArmyRuntime.NATS.Connection

  @cache_ttl_ms 60_000
  @registry_subject "bot_army.registry.bots.list"
  @timeout_ms 5000

  # State: %{tools: [tool_def], cached_at: datetime}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get list of all available MCP tools (request_reply subjects only)."
  @spec list_tools() :: {:ok, [map()]} | {:error, term()}
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc "Force immediate refresh of tool catalog."
  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @impl true
  def init(opts) do
    state = %{
      tools: [],
      cached_at: nil,
      cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, @cache_ttl_ms)
    }

    # Attempt initial fetch
    send(self(), :fetch_tools)
    {:ok, state}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    # Check if cache is fresh
    if cache_fresh?(state) do
      {:reply, {:ok, state.tools}, state}
    else
      # Force refresh
      case fetch_tools_from_registry() do
        {:ok, tools} ->
          new_state = %{state | tools: tools, cached_at: DateTime.utc_now()}
          {:reply, {:ok, tools}, new_state}

        {:error, reason} ->
          Logger.warning("Failed to fetch tools from registry: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_cast(:refresh, state) do
    send(self(), :fetch_tools)
    {:noreply, state}
  end

  @impl true
  def handle_info(:fetch_tools, state) do
    case fetch_tools_from_registry() do
      {:ok, tools} ->
        Logger.info("Tool discovery: found #{length(tools)} MCP tools")

        new_state = %{state | tools: tools, cached_at: DateTime.utc_now()}
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("Failed to fetch tools: #{inspect(reason)}")
        # Retry in 5 seconds
        Process.send_after(self(), :fetch_tools, 5000)
        {:noreply, state}
    end
  end

  # Private

  defp cache_fresh?(state) do
    if state.cached_at do
      age_ms = DateTime.diff(DateTime.utc_now(), state.cached_at, :millisecond)
      age_ms < state.cache_ttl_ms
    else
      false
    end
  end

  defp fetch_tools_from_registry do
    try do
      case GenServer.whereis(Connection) do
        nil ->
          {:error, :nats_connection_unavailable}

        _ ->
          case GenServer.call(Connection, :get_connection, @timeout_ms) do
            {:ok, conn} ->
              # Query registry for all bots
              case Gnat.request(conn, @registry_subject, "{}", receive_timeout: @timeout_ms) do
                {:ok, %{body: body}} ->
                  parse_registry_response(body)

                {:error, :timeout} ->
                  {:error, :registry_timeout}

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end
      end
    rescue
      e ->
        {:error, {:exception, inspect(e)}}
    end
  end

  defp parse_registry_response(body) do
    with {:ok, data} <- Jason.decode(body),
         %{"data" => %{"bots" => bots}} <- data do
      # Extract request_reply subjects from all bots
      tools =
        bots
        |> Enum.flat_map(&extract_tools_from_bot/1)
        |> Enum.sort_by(& &1.name)

      {:ok, tools}
    else
      _ -> {:error, :invalid_registry_response}
    end
  end

  defp extract_tools_from_bot(%{"name" => bot_name, "subjects" => subjects}) do
    subjects
    |> Enum.filter(&is_callable_tool/1)
    |> Enum.map(&to_mcp_tool_definition(&1, bot_name))
  end

  defp callable_tool?(subject) do
    subject["type"] == "request_reply" && exclude_system_subjects(subject)
  end

  defp extract_tools_from_bot(_), do: []

  # Exclude system health and internal subjects
  defp exclude_system_subjects(%{"subject" => subject}) do
    not String.starts_with?(subject, ["system.", "bot_army.registry."])
  end

  defp to_mcp_tool_definition(subject_def, _bot_name) do
    %{
      name: subject_def["subject"],
      description: subject_def["description"] || "Bot Army service",
      inputSchema: %{
        type: "object",
        properties: %{},
        required: []
      },
      timeout_ms: subject_def["timeout_ms"] || 5000
    }
  end
end
