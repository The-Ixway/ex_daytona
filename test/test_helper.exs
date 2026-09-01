# Test Helper
# This file is run before all tests

# Configure ExUnit. Live smoke tests (test/integration/live_test.exs) need a
# real API deployment, so they stay out of the default run — `mix test.live`
# pulls them back in via --include.
ExUnit.configure(exclude: [:live])
ExUnit.start()

# Start Mox for mocking
Mox.defmock(HTTPClientMock, for: Tesla.Adapter)

# Application will be started automatically by Mix
# but we ensure it's running for integration tests
{:ok, _} = Application.ensure_all_started(:bandit)

# Script table for FakeTransports — owned here so it survives the whole run
# (an ETS table owned by an individual test process dies with that test).
_ = :ets.new(:fake_transport_scripts, [:named_table, :public, :set])
