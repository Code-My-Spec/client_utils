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
  [{:client_utils, "~> 0.5.0"}]
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
{:client_utils, github: "Code-My-Spec/client_utils", ref: "REVIEWED_COMMIT_SHA"}
```

Use the reviewed commit selected by your installer and commit `mix.lock`. Update the explicit ref deliberately, run `mix deps.update client_utils`, and test before deploying.

Add `{ClientUtils.Widget, otp_app: :my_app}` before the endpoint in your
supervision tree (it returns `:ignore` until both configuration values are set), and configure `:codemyspec_server_url` and
`:codemyspec_credentials_path` on `:my_app` at runtime. Authorize each host
once as the project owner:

```sh
mix client_utils.authorize --server https://codemyspec.com --project PROJECT_UUID --credentials /private/state/codemyspec.json
```

Open the printed URL and approve the code. The command saves the OAuth client secret and project-scoped refresh
credential with mode 0600; mount that file as a private, persistent runtime secret
and set `CODEMYSPEC_CREDENTIALS_PATH` to its path. Never commit it or place it
under `priv/static`. Visitors never approve a device or receive this credential.
The host obtains short-lived identity-bound socket tokens and renews them while
connected. No deployment key is used to connect the widget. Revoke an installation
at `/oauth/installations`; existing socket tokens expire within 15 minutes, and renewal
and reconnect are refused immediately after revocation. Reauthorize to replace it.

`ClientUtils.CodeMySpecClient` owns device authorization, private credential storage,
renewal, and authenticated HTTP requests. It works independently of the widget's
supervisor. Configure `CODEMYSPEC_SERVER_URL` as the HTTPS server origin and map it
to `:codemyspec_server_url`; map `CODEMYSPEC_CREDENTIALS_PATH` to
`:codemyspec_credentials_path` in runtime config.

```elixir
client = ClientUtils.CodeMySpecClient.new(:my_app)
ClientUtils.CodeMySpecClient.upsert_user(client, %{
  external_id: to_string(user.id), email: user.email, name: user.name
})
```

Call this after registration or profile changes. It returns `{:ok, response}` or
`{:error, reason}`; updates are keyed by email within the approved project. The
host cannot override that project in its payload. The setup command requests
`widget` permission; use `--scope "widget users"` to explicitly request both, or `--scope users` for user-only
installation. The owner sees the permissions before approving. Existing
widget-only grants do not gain user access: reauthorize to approve both. Content
is not included. The widget itself uses the same client's `widget_socket_token/3`.

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
`ClientUtils.WidgetVerifyController`. Keep the `/_cms/verify/widget` route and its existing deploy-key authentication
only if using CodeMySpec's separate inbound provisioning probe. That probe does
not authorize outgoing widget connections. Authorize the host with device flow
and replace the outgoing widget's deploy-key config with the private credential
path. Existing server deploy-key socket support remains for older installations;
new shared clients never fall back to it.

Browser assets (including screenshot capture) ship prebuilt. To change them:
`npm ci --prefix assets && npm run build --prefix assets`; commit the source,
lockfile, and `priv/static/widget.js`. Consumers do not install npm packages.

Installation authorization uses the standard `/oauth/token` refresh grant. The
private credential file is updated with the returned refresh token before making
an API request. Installations created with the earlier custom widget credential
must run `mix client_utils.authorize` again after the server upgrade.
