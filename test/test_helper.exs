Application.ensure_all_started(:mox)

ExUnit.configure(exclude: [:integration, :load, :nats_live])

ExUnit.start()

# Define Mox mocks for external dependencies
Mox.defmock(HTTPClientMock, for: BotArmyMcp.HTTPClient)
