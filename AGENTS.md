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
