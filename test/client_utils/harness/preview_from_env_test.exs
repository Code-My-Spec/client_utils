defmodule ClientUtils.Harness.PreviewFromEnvTest do
  @moduledoc """
  Story 968. An application in a container has no checkout to read, so its
  preview arrives as environment variables instead.

  The two sources exist because there are two ways an app runs, not because one
  is a fallback for the other failing. A container image holds the application
  and nothing else — no `.cms_harness.json`, because nothing onboarded a
  directory that does not exist.
  """
  # Sync: these set OS environment variables, which belong to the node rather
  # than to a test process.
  use ExUnit.Case, async: false

  alias ClientUtils.Harness.Preview

  @vars ~w(
    CMS_PREVIEW_TUNNEL_ID
    CMS_PREVIEW_HOSTNAME
    CMS_PREVIEW_ACCOUNT_TAG
    CMS_PREVIEW_TUNNEL_SECRET
  )

  setup do
    prior = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(prior, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    root = Path.join(System.tmp_dir!(), "preview-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root}
  end

  defp set_env do
    System.put_env("CMS_PREVIEW_TUNNEL_ID", "tunnel-env")
    System.put_env("CMS_PREVIEW_HOSTNAME", "preview-env.codemyspec.com")
    System.put_env("CMS_PREVIEW_ACCOUNT_TAG", "acct-env")
    System.put_env("CMS_PREVIEW_TUNNEL_SECRET", "c2VjcmV0LWVudg==")
  end

  test "a container reads its preview out of the environment", %{root: root} do
    set_env()

    config = Preview.config(root)

    assert config[:tunnel_id] == "tunnel-env"
    assert config[:hostname] == "preview-env.codemyspec.com"
    assert config[:account_tag] == "acct-env"
    assert config[:tunnel_secret] == "c2VjcmV0LWVudg=="
  end

  test "an address with no tunnel behind it is no preview", %{root: root} do
    System.put_env("CMS_PREVIEW_HOSTNAME", "preview-env.codemyspec.com")

    assert Preview.config(root) == [],
           "a hostname with no tunnel resolves to an edge holding no connection to " <>
             "this app, so the frame sits blank with nothing saying why. Better to " <>
             "have no preview than one that cannot answer."
  end

  test "a checkout wins over the environment", %{root: root} do
    set_env()

    File.write!(
      Path.join(root, ".cms_harness.json"),
      Jason.encode!(%{
        "preview_url" => "https://preview-checkout.codemyspec.com",
        "preview_tunnel_id" => "tunnel-checkout"
      })
    )

    config = Preview.config(root)

    assert config[:tunnel_id] == "tunnel-checkout",
           "the environment won over the checkout. They do not compete in practice — " <>
             "a container has no file and a laptop has no reason to export these — so " <>
             "the case this decides is somebody exporting them by hand, and there the " <>
             "checkout is what was actually provisioned."
  end

  test "neither source says anything and the app starts normally", %{root: root} do
    assert Preview.config(root) == []
  end
end
