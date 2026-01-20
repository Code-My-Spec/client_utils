import Config

# Base directory for all agent_test temporary files
# Change this value to relocate lock files, logs, and caller tracking
config :client_utils, :agent_test_dir, ".code_my_spec/internal"

# Suppress debug/info logs from console - only warnings and errors
config :logger, level: :warning

# File backend for debug logging (added at runtime by agent_test)
config :logger, :file_log,
  path: ".code_my_spec/internal/agent_test.log",
  level: :debug,
  format: "$time $metadata[$level] $message\n",
  metadata: [:pid, :mfa]