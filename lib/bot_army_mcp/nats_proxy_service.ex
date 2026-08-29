defmodule BotArmyMcp.NATSProxyService do
  @moduledoc """
  Proxies MCP tool calls through to NATS request/reply.

  Takes an MCP tool call request and routes it to the appropriate NATS subject,
  handling timeouts and error responses gracefully.
  """

  require Logger

  alias BotArmyLibraryRuntime.NATS.Connection

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
    subject = BotArmyMcp.CuratedTools.resolve_subject(tool_name)

    if BotArmyMcp.CircuitBreaker.available?(subject) do
      call_with_connection(Connection, subject, arguments, agent_context, timeout_ms)
    else
      status = BotArmyMcp.CircuitBreaker.status(subject)
      Logger.warning("Circuit breaker open for #{subject}: #{status.last_error}")
      {:error, {:circuit_open, "Too many failures for #{subject}"}}
    end
  end

  # Private

  alias BotArmyMcp.AgentContext

  defp call_with_connection(connection_mod, tool_name, arguments, agent_context, timeout_ms) do
    case GenServer.whereis(connection_mod) do
      nil ->
        {:error, :nats_connection_unavailable}

      _ ->
        case GenServer.call(connection_mod, :get_connection, timeout_ms) do
          {:ok, conn} ->
            execute_nats_request(conn, tool_name, arguments, agent_context, timeout_ms)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp execute_nats_request(conn, subject, arguments, agent_context, timeout_ms) do
    envelope =
      if agent_context do
        AgentContext.build_envelope(agent_context, subject, arguments)
      else
        arguments
      end

    case Jason.encode(envelope) do
      {:ok, body} ->
        result = perform_request(conn, subject, body, timeout_ms)

        case result do
          {:ok, _} -> BotArmyMcp.CircuitBreaker.record_success(subject)
          {:error, reason} -> BotArmyMcp.CircuitBreaker.record_failure(subject, reason)
        end

        result

      {:error, reason} ->
        Logger.error("Failed to encode NATS request: #{inspect(reason)}")
        {:error, {:encode_error, reason}}
    end
  end

  defp perform_request(conn, subject, body, timeout_ms) do
    case Gnat.request(conn, subject, body, receive_timeout: timeout_ms) do
      {:ok, %{body: response_body}} ->
        decode_response(response_body)

      {:error, :timeout} ->
        {:error, {:timeout, "Tool execution exceeded #{timeout_ms}ms"}}

      {:error, reason} ->
        Logger.error("NATS request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp decode_response(response_body) do
    case Jason.decode(response_body) do
      {:ok, data} ->
        unwrap_envelope(data)

      {:error, reason} ->
        Logger.error("Failed to decode NATS response: #{inspect(reason)}")
        {:error, {:decode_error, reason}}
    end
  end

  defp unwrap_envelope(%{"ok" => true, "data" => payload}), do: {:ok, payload}
  defp unwrap_envelope(%{"ok" => true}), do: {:ok, %{}}
  defp unwrap_envelope(%{"ok" => false, "error" => error}), do: {:error, {:tool_error, error}}
  defp unwrap_envelope(data), do: {:ok, data}
end
