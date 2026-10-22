# ClientUtils

An ExUnit formatter with JSON output and distributed test coordination. Designed for editor integrations and CI/CD pipelines that need machine-readable test results and the ability to handle concurrent test requests.

## Features

- **JSON Output** - Machine-readable test results
- **Streaming Mode** - Real-time JSON events as tests complete
- **Distributed Test Coordination** - Multiple concurrent test requests are serialized, with results cached and replayed to waiting callers
- **CLI Passthrough** - Standard ExUnit terminal output is preserved

## Installation

```elixir
def deps do
  [{:client_utils, "~> 0.1.0"}]
end
```

## Basic Usage

Configure the formatter in `test/test_helper.exs`:

```elixir
ExUnit.start(formatters: [ClientUtils.TestFormatter])
```

### File Output

```elixir
ExUnit.start(formatters: [{ClientUtils.TestFormatter, output_file: "test-results.json"}])
```

Or via environment variable:

```bash
EXUNIT_JSON_OUTPUT_FILE=test-results.json mix test
```

### Streaming Mode

Stream test events in real-time while writing the final summary to a file:

```elixir
ExUnit.start(formatters: [{ClientUtils.TestFormatter, streaming: true, output_file: "test-results.json"}])
```

## JSON Output Format

### Final Summary

```json
{
  "stats": {
    "duration": 1234.56,
    "start": "2024-01-15T10:30:00.000000",
    "end": "2024-01-15T10:30:01.234000",
    "passes": 40,
    "failures": 2,
    "pending": 3,
    "tests": 45,
    "suites": 5
  },
  "tests": [
    {"title": "test name", "fullTitle": "ModuleName: test name"}
  ],
  "failures": [
    {
      "title": "failing test",
      "fullTitle": "ModuleName: failing test",
      "error": {
        "file": "test/my_test.exs",
        "line": 42,
        "message": "Assertion failed"
      }
    }
  ],
  "pending": [
    {"title": "skipped test", "fullTitle": "ModuleName: skipped test", "pending": true}
  ]
}
```

### Streaming Events

```json
{"type":"suite:start","start":"2024-01-15T10:30:00.000000"}
{"type":"test:pass","test":{"title":"works","fullTitle":"MyModule: works"}}
{"type":"test:fail","test":{"title":"breaks","fullTitle":"MyModule: breaks","error":{...}}}
{"type":"suite:end","stats":{...}}
```

## Configuration

| Environment Variable      | Description                 |
| ------------------------- | --------------------------- |
| `EXUNIT_JSON_OUTPUT_FILE` | Path for JSON output file   |
| `EXUNIT_JSON_STREAMING`   | Enable streaming mode       |

## License

Apache 2.0