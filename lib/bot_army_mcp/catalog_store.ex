defmodule BotArmyMcp.CatalogStore do
  @moduledoc """
  ETS-backed store for MCP tool catalog entries.

  Three tiers:
  - **Canonical** — built-in tools from `priv/canonical_mcp_tools/`
  - **External** — fetched from GitHub registries (awesome-mcp-servers, etc.)
  - **Registered** — tools explicitly installed via `bot_army.mcp.tools.register`

  Tables:
  - `:mcp_catalog_entries` — `{slug, %{name, description, source, ...}}`
  - `:mcp_registered_tools` — `{tenant_id, slug, config_map}`
  """

  use GenServer
  require Logger

  @catalog_table :mcp_catalog_entries
  @registered_table :mcp_registered_tools
  @canonical_dir "priv/canonical_mcp_tools"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all catalog entries (canonical + external), optionally filtered by source."
  @spec list_entries(keyword()) :: [map()]
  def list_entries(opts \\ []) do
    source_filter = Keyword.get(opts, :source)

    entries =
      :ets.tab2list(@catalog_table)
      |> Enum.map(fn {_key, entry} -> entry end)

    if source_filter do
      Enum.filter(entries, &(&1["source"] == source_filter))
    else
      entries
    end
  end

  @doc "List registered tools for a tenant."
  @spec list_registered(String.t()) :: [map()]
  def list_registered(tenant_id) do
    :ets.match_object(@registered_table, {{tenant_id, :_}, :_})
    |> Enum.map(fn {{^tenant_id, slug}, config} ->
      case lookup_entry(slug) do
        nil -> %{"slug" => slug, "registered" => true, "config" => config}
        entry -> Map.merge(entry, %{"registered" => true, "config" => config})
      end
    end)
  end

  @doc "Look up a single catalog entry by slug."
  @spec lookup_entry(String.t()) :: map() | nil
  def lookup_entry(slug) do
    case :ets.lookup(@catalog_table, slug) do
      [{_key, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Check if a tool is registered for a tenant."
  @spec registered?(String.t(), String.t()) :: boolean()
  def registered?(tenant_id, slug) do
    :ets.lookup(@registered_table, {tenant_id, slug}) != []
  end

  @doc "Register a tool for a tenant with optional config."
  @spec register_tool(String.t(), String.t(), map()) :: :ok
  def register_tool(tenant_id, slug, config \\ %{}) do
    GenServer.call(__MODULE__, {:register, tenant_id, slug, config})
  end

  @doc "Unregister a tool for a tenant."
  @spec unregister_tool(String.t(), String.t()) :: :ok
  def unregister_tool(tenant_id, slug) do
    GenServer.cast(__MODULE__, {:unregister, tenant_id, slug})
  end

  @doc "Upsert external catalog entries (typically from fetcher)."
  @spec upsert_external([map()]) :: :ok
  def upsert_external(entries) when is_list(entries) do
    GenServer.cast(__MODULE__, {:upsert_external, entries})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(@catalog_table, [:set, :named_table, :public, {:read_concurrency, true}])
    :ets.new(@registered_table, [:set, :named_table, :public, {:read_concurrency, true}])

    load_canonical_tools()

    Logger.info(
      "[CatalogStore] Loaded #{Enum.count(:ets.tab2list(@catalog_table))} canonical tools"
    )

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, tenant_id, slug, config}, _from, state) do
    :ets.insert(@registered_table, {{tenant_id, slug}, config})
    Logger.info("[CatalogStore] Registered #{slug} for tenant #{tenant_id}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:unregister, tenant_id, slug}, state) do
    :ets.delete(@registered_table, {tenant_id, slug})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:upsert_external, entries}, state) do
    # First clear old external entries to avoid stale data
    :ets.match_delete(@catalog_table, {:_, %{"source" => "external"}})

    Enum.each(entries, fn entry ->
      slug = entry["slug"] || entry["name"]

      if slug do
        :ets.insert(@catalog_table, {slug, entry})
      end
    end)

    Logger.info("[CatalogStore] Upserted #{length(entries)} external entries")
    {:noreply, state}
  end

  # Private

  defp load_canonical_tools do
    root = Application.app_dir(:bot_army_mcp, @canonical_dir)

    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.each(fn name ->
          path = Path.join(root, name)
          slug = Path.rootname(name)

          case File.read(path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, entry} ->
                  entry = Map.merge(entry, %{"slug" => slug, "source" => "canonical"})
                  :ets.insert(@catalog_table, {slug, entry})

                {:error, reason} ->
                  Logger.warning("[CatalogStore] Failed to parse #{name}: #{inspect(reason)}")
              end

            {:error, reason} ->
              Logger.warning("[CatalogStore] Failed to read #{name}: #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        Logger.warning("[CatalogStore] Failed to list canonical dir: #{inspect(reason)}")
    end
  end
end
