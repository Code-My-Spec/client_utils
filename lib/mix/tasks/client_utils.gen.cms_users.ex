defmodule Mix.Tasks.ClientUtils.Gen.CmsUsers do
  @shortdoc "Generate the CodeMySpec registered-users API endpoint"

  @moduledoc """
  Generates a deploy-key-authenticated controller that exposes this
  application's registered users to the CodeMySpec dashboard.

      mix client_utils.gen.cms_users

  CodeMySpec's `ProjectUsers` context calls `GET /api/cms/users` on the
  client app, authenticating with the project's deploy key, and renders the
  list. This task generates the matching endpoint on the client side.

  ## What it writes

    * `lib/<app>_web/controllers/cms_users_controller.ex` — paginated,
      read-only, deploy-key (Bearer) authenticated. Returns `email` and
      `registered_at` per user.

  It then prints the route + config you need to add (it does not edit your
  router — Phoenix generators leave routing to you).

  ## Options

    * `--schema` — the user Ecto schema module. Defaults to
      `<Base>.Users.User`.
    * `--repo` — the Ecto repo module. Defaults to `<Base>.Repo`.
    * `--web` — the web module. Defaults to `<Base>Web`.

  ## Assumptions

  The user schema has an `email` field and `timestamps()` (`inserted_at`).
  Pass `--schema` if yours differs. The deploy key is read from
  `Application.get_env(:<app>, :deploy_key)` — the same key content sync uses.
  """

  use Mix.Task

  @switches [schema: :string, repo: :string, web: :string]

  @impl true
  def run(argv) do
    {opts, _argv, _invalid} = OptionParser.parse(argv, switches: @switches)

    otp_app =
      Mix.Project.config()[:app] ||
        Mix.raise("client_utils.gen.cms_users must be run inside a Mix project")

    base = otp_app |> to_string() |> Macro.camelize()

    web_module = opts[:web] || "#{base}Web"
    schema = opts[:schema] || "#{base}.Users.User"
    repo = opts[:repo] || "#{base}.Repo"

    assigns = [
      otp_app: otp_app,
      base: base,
      web_module: web_module,
      schema: schema,
      repo: repo,
      schema_alias: module_alias(schema),
      repo_alias: module_alias(repo)
    ]

    context_target = Path.join(["lib", "#{otp_app}", "cms_users.ex"])
    controller_target = Path.join(["lib", "#{otp_app}_web", "controllers", "cms_users_controller.ex"])

    Mix.Generator.create_file(context_target, EEx.eval_file(template_path("cms_users_context"), assigns: assigns))
    Mix.Generator.create_file(controller_target, EEx.eval_file(template_path("cms_users_controller"), assigns: assigns))

    Mix.shell().info(post_install(otp_app, web_module))
  end

  defp module_alias(module), do: module |> String.split(".") |> List.last()

  defp template_path(name) do
    Application.app_dir(:client_utils, "priv/templates/cms_users/#{name}.ex.eex")
  end

  defp post_install(otp_app, web_module) do
    """

    Add the route to your router (inside a JSON `:api` pipeline scope):

        scope "/api/cms", #{web_module} do
          pipe_through :api

          get "/users", CmsUsersController, :index
        end

    Ensure the deploy key is configured (same key CodeMySpec stores on the
    project), e.g. in runtime.exs:

        config :#{otp_app}, deploy_key: System.get_env("DEPLOY_KEY")
    """
  end
end
