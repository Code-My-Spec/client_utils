defmodule ClientUtils.Harness.PreviewFromCheckoutTest do
  @moduledoc """
  Story 968. A generated application reads its preview out of the checkout it
  lives in, at boot, rather than being handed the values by whoever started it.

  The empty cases are the ones that matter. An application with no preview — no
  file, an unreadable one, a checkout that was refused a tunnel — has to start
  normally. Returning anything truthy there leaves `CloudflareTunnel` enabled
  and dialling a tunnel that does not exist, which breaks the ordinary case in
  order to serve the rare one.
  """

  use ExUnit.Case, async: true

  alias ClientUtils.Harness.Preview

  setup do
    root = Path.join(System.tmp_dir!(), "preview-checkout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root}
  end

  defp write_config(root, config) do
    File.write!(Path.join(root, ".cms_harness.json"), Jason.encode!(config))
  end

  test "a provisioned checkout yields everything the tunnel needs", %{root: root} do
    write_config(root, %{
      "working_copy_id" => "wc-1",
      "preview_url" => "https://preview-wc-1.codemyspec.com",
      "preview_tunnel_id" => "tunnel-1",
      "preview_tunnel_secret" => "c2VjcmV0",
      "preview_account_tag" => "acct-1"
    })

    config = Preview.from_checkout(root)

    assert config[:tunnel_id] == "tunnel-1"
    assert config[:tunnel_secret] == "c2VjcmV0"
    assert config[:account_tag] == "acct-1"

    assert config[:hostname] == "preview-wc-1.codemyspec.com",
           "cloudflared routes on a hostname; a URL with its scheme still attached " <>
             "is not one"
  end

  test "the embedder is an origin, not the preview address", %{root: root} do
    write_config(root, %{
      "preview_url" => "https://preview-wc-1.codemyspec.com",
      "preview_tunnel_id" => "tunnel-1"
    })

    config = Preview.from_checkout(root, embedder: "https://dev.codemyspec.com")

    assert config[:embedder] == "https://dev.codemyspec.com",
           "the origin allowed to frame this app is the site that issued the " <>
             "preview, not the preview itself — which is this app"
  end

  describe "an application with no preview starts normally" do
    test "no config file at all", %{root: root} do
      assert Preview.from_checkout(root) == []
    end

    test "a config with no tunnel in it", %{root: root} do
      write_config(root, %{"working_copy_id" => "wc-1", "project_id" => "p-1"})

      assert Preview.from_checkout(root) == [],
             "a checkout that was refused a tunnel — every worktree — would " <>
               "otherwise boot dialling one that does not exist"
    end

    test "a config that cannot be parsed", %{root: root} do
      File.write!(Path.join(root, ".cms_harness.json"), "half a json file")

      assert Preview.from_checkout(root) == []
    end

    test "a blank tunnel id is no tunnel", %{root: root} do
      write_config(root, %{"preview_tunnel_id" => ""})

      assert Preview.from_checkout(root) == []
    end
  end
end
