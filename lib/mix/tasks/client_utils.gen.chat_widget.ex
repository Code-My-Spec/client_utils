defmodule Mix.Tasks.ClientUtils.Gen.ChatWidget do
  @shortdoc "DEPRECATED — moved to cms_gen.support_widget in code_my_spec_generators"

  @moduledoc """
  > #### Deprecated {: .warning}
  >
  > The support widget has been consolidated into the `code_my_spec_generators`
  > package as `mix cms_gen.support_widget`, which is the canonical, maintained
  > version (chat + "Report a problem", wired to the CodeMySpec issue queue).
  > This generator is kept only for existing installs; new apps should use
  > `cms_gen.support_widget`.

  Generates an always-on support widget that connects this application's
  logged-in users to CodeMySpec. One widget, two tabs:

    * **Chat** — live conversation with a CodeMySpec operator.
    * **Feedback** — report an issue (title/severity/description) with an
      optional screenshot.

      mix client_utils.gen.chat_widget

  The widget is a sticky nested LiveView. Per logged-in user, the app's
  **server** opens a Slipstream connection to CodeMySpec authenticated by the
  project deploy key — the key never reaches the browser. Chat messages and
  feedback submissions both ride that one connection; nothing uses OAuth.

  ## What it writes

    * `lib/<app>/code_my_spec/widget_client.ex` — per-user Slipstream client
      (relays chat messages and `submit_feedback`)
    * `lib/<app>/code_my_spec/widget.ex` — registry/supervisor interface
    * `lib/<app>_web/live/chat_widget_live.ex` — the sticky nested LiveView
      (chat + feedback tabs)

  It then prints the dep, supervision, layout, and config you must add (it
  does not edit those — generators leave wiring to you).

  ## Options

    * `--web` — the web module. Defaults to `<Base>Web`.

  ## Assumptions

  phx.gen.auth conventions: `<Base>Web.UserAuth` provides an
  `on_mount {_, :mount_current_scope}` that assigns `current_scope.user`, and
  the app runs `<Base>.PubSub`. The deploy key is read from
  `Application.get_env(:<app>, :deploy_key)` — the same key content sync and
  `client_utils.gen.cms_users` use.
  """

  use Mix.Task

  @switches [web: :string]

  @impl true
  def run(argv) do
    {opts, _argv, _invalid} = OptionParser.parse(argv, switches: @switches)

    otp_app =
      Mix.Project.config()[:app] ||
        Mix.raise("client_utils.gen.chat_widget must be run inside a Mix project")

    base = otp_app |> to_string() |> Macro.camelize()
    web_module = opts[:web] || "#{base}Web"

    assigns = [otp_app: otp_app, base: base, web_module: web_module]

    files = [
      {"widget_client", Path.join(["lib", "#{otp_app}", "code_my_spec", "widget_client.ex"])},
      {"widget", Path.join(["lib", "#{otp_app}", "code_my_spec", "widget.ex"])},
      {"chat_widget_live", Path.join(["lib", "#{otp_app}_web", "live", "chat_widget_live.ex"])}
    ]

    Enum.each(files, fn {name, target} ->
      Mix.Generator.create_file(target, EEx.eval_file(template_path(name), assigns: assigns))
    end)

    Mix.shell().info(post_install(otp_app, base, web_module))
  end

  defp template_path(name) do
    Application.app_dir(:client_utils, "priv/templates/chat_widget/#{name}.ex.eex")
  end

  defp post_install(otp_app, base, web_module) do
    """

    Chat widget generated. To wire it up:

    1. Add slipstream to deps in mix.exs:

        {:slipstream, "~> 1.1"},

    2. Add the registry + supervisor to your supervision tree
       (lib/#{otp_app}/application.ex), before the Endpoint:

        {Registry, keys: :unique, name: #{base}.CodeMySpec.WidgetRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: #{base}.CodeMySpec.WidgetSupervisor},

    3. Render the widget for logged-in users in
       lib/#{otp_app}_web/components/layouts/root.html.heex, before </body>:

        <%= if @current_scope && @current_scope.user do %>
          {live_render(@conn, #{web_module}.ChatWidgetLive, id: "codemyspec-chat", sticky: true)}
        <% end %>

    4. Configure the widget socket URL (the deploy key reuses your existing
       :deploy_key), e.g. in runtime.exs:

        config :#{otp_app},
          codemyspec_widget_url:
            System.get_env("CODEMYSPEC_WIDGET_URL") || "wss://codemyspec.com/widget"

        config :#{otp_app}, :deploy_key, System.get_env("DEPLOY_KEY")

    5. (Optional) Enable feedback screenshots — the capture button dynamically
       imports html-to-image:

        cd assets && npm install html-to-image --prefix .

       Without it, feedback still submits; only the screenshot capture is a no-op.

    6. Run `mix deps.get`, then restart the server.
    """
  end
end
