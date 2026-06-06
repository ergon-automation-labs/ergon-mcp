defmodule BotArmyMcp.NATS.AgentContextResponder do
  @moduledoc """
  Responds to bot queries about current Claude agent context.

  Subject: bot_army.agent.context.get
  Request: {} (no params needed)
  Response: {
    "ok": true,
    "data": {
      "session_id": "<session>",
      "is_active": true,
      "call_count": <int>,
      "user_context": {...}  # optional
    }
  }

  Bots use this to query whether a Claude Code agent is currently
  making requests, so they can adapt their responses.
  """

  use GenServer
  require Logger

  alias BotArmyRuntime.NATS.{Connection, Reply}
  alias BotArmyMcp.AgentContext

  @subject "bot_army.agent.context.get"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :subscribe)
    {:ok, %{subscription: nil}}
  end

  @impl true
  def handle_info(:subscribe, state) do
    case GenServer.whereis(Connection) do
      nil ->
        Logger.warning("NATS.Connection not available, will retry in 5s")
        Process.send_after(self(), :subscribe, 5000)
        {:noreply, state}

      _ ->
        case GenServer.call(Connection, :get_connection, 5000) do
          {:ok, conn} ->
            case Gnat.sub(conn, self(), @subject) do
              {:ok, sub} ->
                Logger.info("Agent context responder subscribed to #{@subject}")
                {:noreply, %{state | subscription: sub, conn: conn}}

              {:error, reason} ->
                Logger.error("Failed to subscribe to #{@subject}: #{inspect(reason)}")
                Process.send_after(self(), :subscribe, 5000)
                {:noreply, state}
            end

          {:error, reason} ->
            Logger.error("Failed to get NATS connection: #{inspect(reason)}")
            Process.send_after(self(), :subscribe, 5000)
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:msg, %{reply_to: reply_to} = msg}, state) when is_binary(reply_to) do
    # Return current agent context info
    response =
      Reply.ok(%{
        "available" => true,
        "implementation" => "Phase 2 agent context tracking"
      })

    reply_traced(state.conn, reply_to, Jason.encode!(response))
    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp reply_traced(conn, reply_to, response) do
    case Gnat.pub(conn, reply_to, response) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to reply to agent context query: #{inspect(reason)}")
    end
  end
end
