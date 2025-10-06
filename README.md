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

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/exunit_json_formatter](https://hexdocs.pm/exunit_json_formatter).
