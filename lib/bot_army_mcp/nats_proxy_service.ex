defmodule BotArmyMcp.NATSProxyService do
  @moduledoc """
  Proxies MCP tool calls through to NATS request/reply.

  Takes an MCP tool call request and routes it to the appropriate NATS subject,
  handling timeouts and error responses gracefully.
  """

  require Logger

  alias BotArmyRuntime.NATS.Connection

  @default_timeout_ms 5000

  @doc """
  Call a Bot Army tool via NATS with optional agent context.

  ## Parameters
  - tool_name: NATS subject to call (e.g., "gtd.task.list")
  - arguments: Map of arguments to send as JSON
  - agent_context: Optional agent context (for Claude Code sessions)
  - timeout_ms: Optional timeout (default 5000ms)

  ## Returns
  - {:ok, response} - Decoded JSON response
  - {:error, reason} - Error tuple

  ## Agent Context
  When agent_context is provided, injects Claude Code session metadata
  into the NATS request so bots can tailor responses accordingly.
  """
  @spec call_tool(String.t(), map(), map() | nil, non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def call_tool(
        tool_name,
        arguments \\ %{},
        agent_context \\ nil,
        timeout_ms \\ @default_timeout_ms
      ) do
    try do
      if not BotArmyMcp.CircuitBreaker.available?(tool_name) do
        status = BotArmyMcp.CircuitBreaker.status(tool_name)
        Logger.warning("Circuit breaker open for #{tool_name}: #{status.last_error}")
        {:error, {:circuit_open, "Too many failures for #{tool_name}"}}
      else
        case GenServer.whereis(Connection) do
          nil ->
            {:error, :nats_connection_unavailable}

          _ ->
            case GenServer.call(Connection, :get_connection, timeout_ms) do
              {:ok, conn} ->
                execute_nats_request(conn, tool_name, arguments, agent_context, timeout_ms)

              {:error, reason} ->
                {:error, reason}
            end
        end
      end
    rescue
      e ->
        Logger.error("Exception in NATS proxy: #{inspect(e)}")
        {:error, {:exception, inspect(e)}}
    end
  end

  # Private

  alias BotArmyMcp.AgentContext

  defp execute_nats_request(conn, subject, arguments, agent_context, timeout_ms) do
    # Build request body with optional agent context
    body =
      if agent_context do
        AgentContext.build_envelope(agent_context, subject, arguments) |> Jason.encode!()
      else
        Jason.encode!(arguments)
      end

    result =
      case Gnat.request(conn, subject, body, receive_timeout: timeout_ms) do
        {:ok, %{body: response_body}} ->
          case Jason.decode(response_body) do
            {:ok, data} ->
              # Unwrap from standard Bot Army response envelope
              case data do
                %{"ok" => true, "data" => payload} ->
                  {:ok, payload}

                %{"ok" => true} ->
                  {:ok, data}

                %{"ok" => false, "error" => error} ->
                  {:error, {:tool_error, error}}

                _ ->
                  {:ok, data}
              end

            {:error, reason} ->
              Logger.error("Failed to decode NATS response: #{inspect(reason)}")
              {:error, {:decode_error, reason}}
          end

        {:error, :timeout} ->
          {:error, {:timeout, "Tool execution exceeded #{timeout_ms}ms"}}

        {:error, reason} ->
          Logger.error("NATS request failed: #{inspect(reason)}")
          {:error, reason}
      end

    # Record result in circuit breaker
    case result do
      {:ok, _} ->
        BotArmyMcp.CircuitBreaker.record_success(subject)

      {:error, reason} ->
        BotArmyMcp.CircuitBreaker.record_failure(subject, reason)
    end

    result
  end
end
