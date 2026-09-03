import Config

if config_env() != :test do
  alias BotArmyLibraryRuntime.ConfigLoader

  nats_servers =
    case ConfigLoader.get("NATS_SERVERS") do
      nil ->
        nats_host = ConfigLoader.get("NATS_HOST", "localhost")
        nats_port = ConfigLoader.get("NATS_PORT", "4223") |> String.to_integer()
        [{nats_host, nats_port}]

      servers_string ->
        servers_string
        |> String.split()
        |> Enum.map(fn server_spec ->
          case String.split(server_spec, ":") do
            [host, port_str] -> {host, String.to_integer(port_str)}
            [host] -> {host, 4223}
            _ -> {"localhost", 4223}
          end
        end)
    end

  config :bot_army_library_runtime, :nats,
    servers: nats_servers,
    ping_interval: 30_000,
    max_reconnect_attempts: 10,
    reconnect_delay_ms: 1000
end