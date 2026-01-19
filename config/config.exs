import Config

# Base directory for all agent_test temporary files
# Change this value to relocate lock files, logs, and caller tracking
config :client_utils, :agent_test_dir, ".code_my_spec/internal"

# Disable default console handler to prevent cluttering terminal output
config :logger, :default_handler, false

# File backend for debug logging
config :logger, :file_log,
  path: ".code_my_spec/internal/agent_test.log",
  level: :debug,
  format: "$time $metadata[$level] $message\n",
  metadata: [:pid, :mfa]