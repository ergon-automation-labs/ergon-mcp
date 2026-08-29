defmodule BotArmyMcp.NATS.Consumer do
  @moduledoc """
  NATS message consumer for mcp.

  Subscribes to NATS subjects and routes messages to handlers.
  Uses standardized Reply format for request/reply patterns.

  All request/reply handlers should return responses using Reply helpers:
  - Reply.ok(data) for success
  - Reply.error(message, code) for errors
  """

  use GenServer
  require Logger

  alias BotArmyLibraryCore.NATS.Decoder
  alias BotArmyLibraryRuntime.NATS.{Connection, Reply}
  alias BotArmyLibraryRuntime.Tracing
  alias BotArmyLibraryRuntime.Registry

  alias BotArmyMcp.{CatalogStore, ConfigStore}

  @reconnect_delay_ms 5000
  @registry_heartbeat_ms 20_000
  @version Mix.Project.config()[:version]

  # Register subjects with their metadata for runtime discovery
  @status_subject "bot_army.mcp.status"
  @tools_execute_subject "bot_army.mcp.tools.execute"
  @catalog_suggest_subject "bot_army.mcp.catalog.suggest"
  @tools_register_subject "bot_army.mcp.tools.register"
  @config_get_subject "bot_army.mcp.config.get"
  @config_set_subject "bot_army.mcp.config.set"
  @config_list_subject "bot_army.mcp.config.list"

  @subjects [
    %{
      subject: @status_subject,
      type: :request_reply,
      description: "Return MCP bridge status and registered tools"
    },
    %{
      subject: @tools_execute_subject,
      type: :request_reply,
      description: "Execute an MCP tool with sandboxed parameters"
    },
    %{
      subject: @catalog_suggest_subject,
      type: :request_reply,
      description: "Suggest MCP tools from canonical and external catalogs"
    },
    %{
      subject: @tools_register_subject,
      type: :request_reply,
      description: "Register an MCP tool for a tenant"
    },
    %{
      subject: @config_get_subject,
      type: :request_reply,
      description: "Get a config value for a tenant/tool"
    },
    %{
      subject: @config_set_subject,
      type: :request_reply,
      description: "Set a config value for a tenant/tool"
    },
    %{
      subject: @config_list_subject,
      type: :request_reply,
      description: "List config keys for a tenant/tool"
    },
    %{
      subject: "system.health.mcp",
      type: :publish,
      description: "MCP bot health pulse"
    }
  ]

  @tools [
    %{
      "name" => "nats_server_info",
      "description" => "Return NATS connection status and server info"
    },
    %{
      "name" => "nats_subject_reference",
      "description" => "Return known Bot Army NATS subject families"
    },
    %{
      "name" => "registry_list_bots",
      "description" => "Query runtime registry for registered bots"
    },
    %{
      "name" => "registry_list_subjects",
      "description" => "Query runtime registry for known NATS subjects"
    }
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("Starting NATS consumer")

    state = %{
      subscriptions: [],
      conn: nil,
      opts: opts
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    try do
      case GenServer.call(Connection, :get_connection, 5000) do
        {:ok, conn} ->
          Connection.subscribe_to_status()
          Logger.info("Connected to NATS, subscribing to topics")

          subscriptions =
            subscribe_subjects(conn, [
              @status_subject,
              @tools_execute_subject,
              @catalog_suggest_subject,
              @tools_register_subject,
              @config_get_subject,
              @config_set_subject,
              @config_list_subject
            ])

          # Register subjects for runtime discovery
          deployment_status =
            Application.get_env(:bot_army_mcp, :deployment_status, "experimental")

          Registry.register("mcp", @subjects, @version, deployment_status)
          Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)

          {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

        {:error, _reason} ->
          Logger.warning("NATS connection not ready, will retry")
          Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
          {:noreply, state}
      end
    rescue
      e ->
        Logger.warning(
          "NATS subscribe failed during connect: #{Exception.message(e)}, will retry"
        )

        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:registry_heartbeat, state) do
    if state.subscriptions != [] do
      deployment_status = Application.get_env(:bot_army_mcp, :deployment_status, "experimental")
      Registry.register("mcp", @subjects, @version, deployment_status)
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers), fn ->
      Logger.debug("Received NATS message on subject: #{msg.topic}")
      dispatch_message(msg, state)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("Disconnected from NATS, will reconnect")
    Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("Reconnected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  defp dispatch_message(msg, state) do
    if msg.reply_to do
      dispatch_request_reply(msg, state)
    else
      dispatch_pub_sub(msg)
    end
  end

  defp dispatch_request_reply(msg, state) do
    case msg.topic do
      @status_subject -> handle_status(msg, state)
      @tools_execute_subject -> handle_tools_execute(msg, state)
      @catalog_suggest_subject -> handle_catalog_suggest(msg, state)
      @tools_register_subject -> handle_tools_register(msg, state)
      @config_get_subject -> handle_config_get(msg, state)
      @config_set_subject -> handle_config_set(msg, state)
      @config_list_subject -> handle_config_list(msg, state)
      _ -> Logger.debug("Unknown request/reply subject: #{msg.topic}")
    end
  end

  defp dispatch_pub_sub(msg) do
    case Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        route_message(decoded_message, msg.topic)

      {:error, reason} ->
        Logger.warning("Failed to decode message from #{msg.topic}: #{inspect(reason)}")
    end
  end

  defp subscribe_subjects(conn, subjects) do
    Enum.map(subjects, &do_subscribe(conn, &1))
    |> Enum.filter(&(not is_nil(&1)))
  end

  defp do_subscribe(conn, subject) do
    case Gnat.sub(conn, self(), subject) do
      {:ok, sub} ->
        Logger.info("Subscribed to #{subject}")
        sub

      {:error, reason} ->
        Logger.error("Failed to subscribe to #{subject}: #{inspect(reason)}")
        nil
    end
  end

  # Message routing
  defp route_message(_message, topic) do
    Logger.debug("Routing message from #{topic}")
  end

  defp handle_status(msg, state) do
    response =
      Reply.ok(%{
        "service" => "mcp",
        "version" => @version,
        "status" => "online",
        "tools" => @tools,
        "mcp_server" => "bot_army_mcp",
        "mcp_version" => "1.2.0"
      })

    if state.conn do
      Gnat.pub(state.conn, msg.reply_to, response)
    end
  end

  defp handle_tools_execute(msg, state) do
    response =
      case Decoder.decode(msg.body) do
        {:ok, payload} ->
          tool = Map.get(payload, "tool")
          params = Map.get(payload, "params", %{})
          execute_tool(tool, params)

        {:error, reason} ->
          Reply.error("invalid payload: #{inspect(reason)}", :bad_request)
      end

    if state.conn do
      Gnat.pub(state.conn, msg.reply_to, response)
    end
  end

  defp execute_tool(nil, _) do
    Reply.error("missing tool name", :bad_request)
  end

  defp execute_tool("nats_server_info", _params) do
    case GenServer.call(Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        info = Gnat.info(conn)

        Reply.ok(%{
          "connected" => true,
          "server_id" => Map.get(info, :server_id, "unknown"),
          "server_name" => Map.get(info, :server_name, "unknown")
        })

      {:error, reason} ->
        Reply.error("not connected: #{inspect(reason)}", :nats_error)
    end
  end

  defp execute_tool("nats_subject_reference", _params) do
    Reply.ok(%{
      "reference" => "bridge.> | gtd.> | llm.> | job.> | system.health.> | events.>"
    })
  end

  defp execute_tool("registry_list_bots", _params) do
    case Publisher.request("bot_army.registry.bots.list", %{}, timeout_ms: 5_000) do
      {:ok, resp} -> Reply.ok(resp)
      {:error, reason} -> Reply.error(inspect(reason), :registry_error)
    end
  end

  defp execute_tool("registry_list_subjects", _params) do
    case Publisher.request("bot_army.registry.subjects.list", %{}, timeout_ms: 5_000) do
      {:ok, resp} -> Reply.ok(resp)
      {:error, reason} -> Reply.error(inspect(reason), :registry_error)
    end
  end

  defp execute_tool(tool, _params) do
    Reply.error("unknown tool: #{tool}", :not_found)
  end

  # Catalog suggest
  defp handle_catalog_suggest(msg, state) do
    response =
      case Decoder.decode(msg.body) do
        {:ok, payload} ->
          query = Map.get(payload, "query", "")
          tenant_id = Map.get(payload, "tenant_id", "default")
          limit = Map.get(payload, "limit", 8)

          installed_slugs =
            CatalogStore.list_registered(tenant_id)
            |> Enum.map(& &1["slug"])
            |> MapSet.new()

          all_entries = CatalogStore.list_entries()

          suggestions =
            all_entries
            |> Enum.reject(fn entry -> MapSet.member?(installed_slugs, entry["slug"]) end)
            |> rank_by_query(query)
            |> Enum.take(limit)

          Reply.ok(%{
            "tenant_id" => tenant_id,
            "query" => query,
            "installed_count" => MapSet.size(installed_slugs),
            "suggestions" => suggestions
          })

        {:error, reason} ->
          Reply.error("invalid payload: #{inspect(reason)}", :bad_request)
      end

    if state.conn do
      Gnat.pub(state.conn, msg.reply_to, response)
    end
  end

  defp rank_by_query(entries, "") do
    entries
  end

  defp rank_by_query(entries, query) do
    tokens =
      query
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, " ")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(&(String.length(&1) < 3))

    if tokens == [] do
      entries
    else
      entries
      |> Enum.map(fn entry ->
        hay =
          [
            entry["slug"] || "",
            entry["name"] || "",
            entry["description"] || "",
            Enum.join(entry["tags"] || [], " ")
          ]
          |> Enum.join(" ")
          |> String.downcase()

        score = Enum.count(tokens, &String.contains?(hay, &1))
        {score, entry}
      end)
      |> Enum.sort_by(fn {score, entry} -> {-score, entry["slug"]} end)
      |> Enum.map(fn {_score, entry} -> entry end)
    end
  end

  # Tool registration
  defp handle_tools_register(msg, state) do
    response =
      case Decoder.decode(msg.body) do
        {:ok, payload} -> build_register_response(payload)
        {:error, reason} -> Reply.error("invalid payload: #{inspect(reason)}", :bad_request)
      end

    if state.conn do
      Gnat.pub(state.conn, msg.reply_to, response)
    end
  end

  defp build_register_response(payload) do
    slug = Map.get(payload, "slug")

    if is_nil(slug) or slug == "" do
      Reply.error("missing slug", :bad_request)
    else
      do_register_lookup(slug, payload)
    end
  end

  defp do_register_lookup(slug, payload) do
    tenant_id = Map.get(payload, "tenant_id", "default")
    config = Map.get(payload, "config", %{})

    case CatalogStore.lookup_entry(slug) do
      nil -> Reply.error("tool not found in catalog: #{slug}", :not_found)
      entry -> do_register_validate(entry, slug, tenant_id, config)
    end
  end

  defp do_register_validate(entry, slug, tenant_id, config) do
    required = Map.get(entry, "requires_config", [])

    missing =
      Enum.reject(required, fn key ->
        Map.has_key?(config, key) or ConfigStore.keys_present?(tenant_id, slug, [key])
      end)

    if missing != [] do
      Reply.error(
        "missing required config keys: #{Enum.join(missing, ", ")}",
        :missing_config
      )
    else
      CatalogStore.register_tool(tenant_id, slug, config)

      Reply.ok(%{
        "slug" => slug,
        "tenant_id" => tenant_id,
        "registered" => true,
        "config_keys" => Map.keys(config)
      })
    end
  end

  # Config handlers
  defp handle_config_get(msg, state) do
    response =
      case Decoder.decode(msg.body) do
        {:ok, payload} -> do_config_get(payload)
        {:error, reason} -> Reply.error("invalid payload: #{inspect(reason)}", :bad_request)
      end

    if state.conn do
      Gnat.pub(state.conn, msg.reply_to, response)
    end
  end

  defp do_config_get(payload) do
    tenant_id = Map.get(payload, "tenant_id", "default")
    tool_slug = Map.get(payload, "tool_slug")
    key = Map.get(payload, "key")

    if is_nil(tool_slug) or is_nil(key) do
      Reply.error("missing tool_slug or key", :bad_request)
    else
      case ConfigStore.get(tenant_id, tool_slug, key) do
        {:ok, value} ->
          Reply.ok(%{
            "tenant_id" => tenant_id,
            "tool_slug" => tool_slug,
            "key" => key,
            "value" => value
          })

        {:error, :not_found} ->
          Reply.error("config not found", :not_found)
      end
    end
  end

  defp handle_config_set(msg, state) do
    response =
      case Decoder.decode(msg.body) do
        {:ok, payload} ->
          tenant_id = Map.get(payload, "tenant_id", "default")
          tool_slug = Map.get(payload, "tool_slug")
          key = Map.get(payload, "key")
          value = Map.get(payload, "value")

          if is_nil(tool_slug) or is_nil(key) or is_nil(value) do
            Reply.error("missing tool_slug, key, or value", :bad_request)
          else
            ConfigStore.set(tenant_id, tool_slug, key, to_string(value))

            Reply.ok(%{
              "tenant_id" => tenant_id,
              "tool_slug" => tool_slug,
              "key" => key,
              "set" => true
            })
          end

        {:error, reason} ->
          Reply.error("invalid payload: #{inspect(reason)}", :bad_request)
      end

    if state.conn do
      Gnat.pub(state.conn, msg.reply_to, response)
    end
  end

  defp handle_config_list(msg, state) do
    response =
      case Decoder.decode(msg.body) do
        {:ok, payload} ->
          tenant_id = Map.get(payload, "tenant_id", "default")
          tool_slug = Map.get(payload, "tool_slug")

          if is_nil(tool_slug) do
            Reply.error("missing tool_slug", :bad_request)
          else
            entries = ConfigStore.list(tenant_id, tool_slug)
            Reply.ok(%{"tenant_id" => tenant_id, "tool_slug" => tool_slug, "entries" => entries})
          end

        {:error, reason} ->
          Reply.error("invalid payload: #{inspect(reason)}", :bad_request)
      end

    if state.conn do
      Gnat.pub(state.conn, msg.reply_to, response)
    end
  end

  # Request/reply handlers
  # defp handle_task_list(msg, state) do
  #   response =
  #     case get_tasks() do
  #       {:ok, tasks} ->
  #         Reply.ok(%{"tasks" => tasks})
  #
  #       {:error, reason} ->
  #         Reply.error(inspect(reason), :list_failed)
  #     end
  #
  #   if state.conn do
  #     Gnat.pub(state.conn, msg.reply_to, response)
  #   end
  # end
end
