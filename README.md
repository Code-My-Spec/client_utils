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

| Environment Variable      | Description                                                                 |
| ------------------------- | --------------------------------------------------------------------------- |
| `EXUNIT_JSON_OUTPUT_FILE` | Path for JSON output file                                                   |
| `EXUNIT_JSON_STREAMING`   | Enable streaming mode                                                       |
| `CMS_HARNESS_NODE`        | The harness node a run reports to; set, the run joins it and outlives it    |
| `CMS_RUN_OUTPUT`          | File the linked run writes its own stdout and stderr to                     |
| `CMS_RUN_RESULT`          | File a linked run writes its unacknowledged events to if no harness takes them |

## License

Apache 2.0
## Shared support widget

The widget implementation lives in this library. Host applications provide only
an authentication adapter and configuration. Chat and issue reports go directly
from the host backend to CodeMySpec; there is no offline store.

```elixir
{:client_utils, github: "Code-My-Spec/client_utils", branch: "main"}
```

Commit `mix.lock`. `mix deps.get` uses that exact revision; advance it with
`mix deps.update client_utils`, then test before deploying.

Add `{ClientUtils.Widget, otp_app: :my_app}` before the endpoint in your
supervision tree, and configure `:codemyspec_widget_url` and `:deploy_key` on
`:my_app` at runtime. The deploy key stays in the backend.

```elixir
defmodule MyAppWeb.SupportWidgetLive do
  use ClientUtils.SupportWidgetLive
  on_mount {MyAppWeb.UserAuth, :mount_current_scope}
end
```

Omit the `on_mount` hook for anonymous-only applications. Identity comes from the
server-authenticated `current_scope.user`; anonymous sessions use their signed
session identity. Never assign a current user from browser event parameters.
Render the adapter with `live_render` in the root layout (sticky, with a stable
id). Import `CmsSupportWidget` and `CmsChatScroll` from
`../../deps/client_utils/priv/static/widget.js` into your LiveSocket hooks, and add
`@source "../../deps/client_utils/lib";` to Tailwind CSS. The widget uses the host's
existing Heroicons CSS and daisyUI theme, matching Phoenix's default styling.
`mix cms_gen.support_widget` installs this wiring for generated applications.

For existing generated widgets, replace the LiveView with the adapter above,
remove the generated `Widget` and `WidgetClient` modules and their old Registry /
DynamicSupervisor children, and delegate the verify controller's `create/2` to
`ClientUtils.WidgetVerifyController`. Keep the existing deploy-key configuration
and `/_cms/verify/widget` route.

Browser assets (including screenshot capture) ship prebuilt. To change them:
`npm ci --prefix assets && npm run build --prefix assets`; commit the source,
lockfile, and `priv/static/widget.js`. Consumers do not install npm packages.
