import Config

# Test environment configuration

# Configure logging for tests
config :logger, level: :warning

# Example: Configure test-specific settings
# config :your_package_name,
#   base_url: "http://localhost:4001"

# Example: Disable retries in tests for faster execution
# config :your_package_name,
#   retry: false

# Configure ExUnit
config :ex_unit,
  capture_log: true,
  assert_receive_timeout: 500
