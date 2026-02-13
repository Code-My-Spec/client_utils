# Notes for AI Agents

## Testing Integration Tests

The fixture project at `fixtures/test_phoenix_project` must use a **path dependency** to test local changes:

```elixir
{:client_utils, path: "../.."}
```

Before publishing to Hex, change it back to a version dependency:

```elixir
{:client_utils, "~> 0.1.4"}
```

## Key Implementation Details

### replay_to_cli/1 in lib/mix/tasks/agent_test.ex

This function replays cached test events to the CLI for "waiter" processes (processes that didn't run tests but are replaying cached results).

**Critical**: The function uses `GenServer.cast` (async) to send events to `ExUnit.CLIFormatter`. To prevent truncated output:

1. **Wait for message processing**: Use `:sys.get_state(cli, timeout)` after casting all events. This is a synchronous call that ensures all previous casts are processed.

2. **Stop GenServer cleanly**: Call `GenServer.stop(cli, :normal, timeout)` to flush any remaining output.

3. **Print fallback summary**: Always print the test summary (`IO.puts`) after stopping the GenServer, because the CLIFormatter may not print it correctly for replayed events.

```elixir
# Wait for all casts to be processed
try do
  :sys.get_state(cli, 5000)
catch
  :exit, _ -> :ok
end

# Stop cleanly to flush output
try do
  GenServer.stop(cli, :normal, 5000)
catch
  :exit, _ -> :ok
end

# Print summary (CLIFormatter may not print it for replays)
IO.puts("\nFinished in 0.0 seconds (0.0s async, 0.0s sync)")
IO.puts("#{total_tests} #{test_word}, #{fail_count} #{fail_word}")
```

Without these steps, the process may exit before output is fully written, resulting in truncated test output (dots appear but no summary line).
