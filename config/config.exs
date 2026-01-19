import Config

# Disable default console handler to prevent cluttering terminal output
config :logger, :default_handler, false

# File backend for debug logging
config :logger, :file_log,
  path: ".code_my_spec/agent_test.log",
  level: :debug,
  format: "$time $metadata[$level] $message\n",
  metadata: [:pid, :mfa]