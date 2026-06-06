defmodule BotArmyMcp.MCPServer do
  @moduledoc """
  Manages the MCP WebSocket server lifecycle.

  Starts a Cowboy HTTP server with WebSocket support for MCP protocol
  connections. Claude Code clients can connect to ws://localhost:{port}/mcp
  """

  require Logger

  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, 14_223)

    case start_server(port) do
      {:ok, _} ->
        Logger.info("MCP server started on port #{port}")
        {:ok, self()}

      {:error, reason} ->
        Logger.error("Failed to start MCP server: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Start the MCP WebSocket server on the specified port"
  @spec start_server(non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def start_server(port) do
    dispatch = [
      {:_,
       [
         {"/mcp", BotArmyMcp.MCPWebSocketHandler, []},
         {:_, Plug.Cowboy.Handler, {BotArmyMcp.HealthPlug, []}}
       ]}
    ]

    :cowboy.start_clear(
      :mcp_server,
      [port: port],
      %{env: [dispatch: dispatch]}
    )
  end

  @doc "Stop the MCP server"
  @spec stop_server() :: :ok
  def stop_server do
    :cowboy.stop_listener(:mcp_server)
  end
end

# Health check endpoint (for monitoring)
defmodule BotArmyMcp.HealthPlug do
  @moduledoc "HTTP health check endpoint"

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => "ok"}))
  end
end
