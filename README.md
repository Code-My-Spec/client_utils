# ExUnitJsonFormatter

An ExUnit formatter that outputs a series of JSON objects.

Inspired and designed to be compatible with mocha-json-streamier-reporter

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `exunit_json_formatter` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:exunit_json_formatter, "~> 0.1.0"}]
end
```

## Usage

### Output to stdout (default)

Configure the formatter in `test/test_helper.exs`:

```elixir
ExUnit.start(formatters: [ExUnitJsonFormatter])
```

### Output to file

There are multiple ways to configure file output:

#### 1. Via test_helper.exs (recommended)

```elixir
ExUnit.start(formatters: [{ExUnitJsonFormatter, output_file: "test-results.json"}])
```

#### 2. Via environment variable

```bash
EXUNIT_JSON_OUTPUT_FILE=test-results.json mix test --formatter ExUnitJsonFormatter
```

or

```bash
export EXUNIT_JSON_OUTPUT_FILE=test-results.json
mix test --formatter ExUnitJsonFormatter
```

#### 3. Via mix.exs configuration

```elixir
def project do
  [
    # ...
    test_coverage: [
      tool: ExUnitJsonFormatter,
      output_file: "test-results.json"
    ]
  ]
end
```

**Note:** Options specified in `test_helper.exs` take precedence over environment variables.

File output is useful when you need clean JSON output separate from test logs and other CLI output.

### Streaming mode

Streaming mode emits individual JSON events to stdout as tests complete, while still generating the final summary blob at the end.

#### Via test_helper.exs

```elixir
ExUnit.start(formatters: [{ExUnitJsonFormatter, streaming: true, output_file: "test-results.json"}])
```

#### Via environment variable

```bash
EXUNIT_JSON_STREAMING=true EXUNIT_JSON_OUTPUT_FILE=test-results.json mix test --formatter ExUnitJsonFormatter
```

or

```bash
export EXUNIT_JSON_STREAMING=true
export EXUNIT_JSON_OUTPUT_FILE=test-results.json
mix test --formatter ExUnitJsonFormatter
```

In streaming mode:
- Individual test events are streamed to stdout as they happen (`test:pass`, `test:fail`, `test:pending`)
- Suite events are emitted to stdout (`suite:start`, `suite:end`)
- The final complete JSON summary is written to the output file (or stdout if no file is configured)

This is useful when you want real-time feedback on test execution while also generating a complete test report.

#### Example streaming output

```json
{"type":"suite:start","start":"2024-01-01T12:00:00.000000"}
{"type":"test:pass","test":{"title":"should work","fullTitle":"MyModule: should work"}}
{"type":"test:fail","test":{"title":"should fail","fullTitle":"MyModule: should fail","err":{...}}}
{"type":"suite:end","stats":{...}}
{"stats":{...},"tests":[...],"failures":[...],"pending":[...]}
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/exunit_json_formatter](https://hexdocs.pm/exunit_json_formatter).
