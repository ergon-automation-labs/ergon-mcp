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

  alias BotArmyCore.NATS.Decoder
  alias BotArmyRuntime.NATS.{Connection, Reply, Tracing}
  alias BotArmyRuntime.Registry

  @reconnect_delay_ms 5000
  @version Mix.Project.config()[:version]

  # Register subjects with their metadata for runtime discovery
  @status_subject "bot_army.mcp.status"
  @tools_execute_subject "bot_army.mcp.tools.execute"

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
    case GenServer.call(Connection, :get_connection, 5000) do
      {:ok, conn} ->
        Connection.subscribe_to_status()
        Logger.info("Connected to NATS, subscribing to topics")

        subscriptions = subscribe_subjects(conn, [@status_subject, @tools_execute_subject])

        # Register subjects for runtime discovery
        Registry.register("mcp", @subjects, @version)

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

      {:error, _reason} ->
        Logger.warning("NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers), fn ->
      Logger.debug("Received NATS message on subject: #{msg.topic}")
      dispatch_message(msg, state)
    end)

    {:noreply, state}
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

  defp subscribe_subjects(conn, subjects) do
    Enum.map(subjects, &do_subscribe(conn, &1 / 1))
    |> Enum.filter(&(not is_nil(&1 / 1)))
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
