defmodule BotArmyMcp.ConfigStore do
  @moduledoc """
  Key-value config store for MCP tool settings and API secrets.

  Scoped per tenant + tool. Values are stored as binaries and can be
  retrieved at tool execution time.

  Security:
  - Values live in ETS (memory only, not persisted to disk by default).
  - Future: encryption at rest via application env key.

  NATS subjects:
  - `bot_army.mcp.config.get` — retrieve a config value
  - `bot_army.mcp.config.set` — store a config value
  - `bot_army.mcp.config.list` — list all keys for a tenant/tool
  """

  use GenServer
  require Logger

  @table :mcp_config_store

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get a config value for tenant/tool/key."
  @spec get(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get(tenant_id, tool_slug, key) do
    case :ets.lookup(@table, {tenant_id, tool_slug, key}) do
      [{_key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @doc "Set a config value for tenant/tool/key."
  @spec set(String.t(), String.t(), String.t(), String.t()) :: :ok
  def set(tenant_id, tool_slug, key, value) when is_binary(value) do
    GenServer.call(__MODULE__, {:set, tenant_id, tool_slug, key, value})
  end

  @doc "List all config keys for a tenant/tool."
  @spec list(String.t(), String.t()) :: [map()]
  def list(tenant_id, tool_slug) do
    :ets.match_object(@table, {{tenant_id, tool_slug, :_}, :_})
    |> Enum.map(fn {{^tenant_id, ^tool_slug, key}, value} ->
      %{
        "key" => key,
        "value" => value,
        "redacted" => redact?(key, value)
      }
    end)
  end

  @doc "Delete a config value."
  @spec delete(String.t(), String.t(), String.t()) :: :ok
  def delete(tenant_id, tool_slug, key) do
    GenServer.cast(__MODULE__, {:delete, tenant_id, tool_slug, key})
  end

  @doc "Check if all required keys for a tool are present."
  @spec keys_present?(String.t(), String.t(), [String.t()]) :: boolean()
  def keys_present?(tenant_id, tool_slug, required_keys) do
    Enum.all?(required_keys, fn key ->
      :ets.lookup(@table, {tenant_id, tool_slug, key}) != []
    end)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :public, {:read_concurrency, true}])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:set, tenant_id, tool_slug, key, value}, _from, state) do
    :ets.insert(@table, {{tenant_id, tool_slug, key}, value})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:delete, tenant_id, tool_slug, key}, state) do
    :ets.delete(@table, {tenant_id, tool_slug, key})
    {:noreply, state}
  end

  # Private

  defp redact?(key, value) do
    sensitive = ["api_key", "token", "secret", "password", "private_key"]

    if Enum.any?(sensitive, &String.contains?(String.downcase(key), &1 / 1)) do
      mask(value)
    else
      value
    end
  end

  defp mask(value) when byte_size(value) <= 8, do: String.duplicate("*", byte_size(value))

  defp mask(value) do
    visible = max(div(byte_size(value), 4), 2)
    prefix = String.slice(value, 0, visible)
    suffix = String.slice(value, -visible, visible)
    "#{prefix}#{String.duplicate("*", byte_size(value) - visible * 2)}#{suffix}"
  end
end
