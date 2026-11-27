defmodule Mix.Tasks.ClientUtils.Gen.LoopRecipesTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  test "installs loop.just, and a justfile that imports it can replace one recipe", %{
    tmp_dir: dir
  } do
    File.cd!(dir, fn -> Mix.Tasks.ClientUtils.Gen.LoopRecipes.run([]) end)

    File.write!(Path.join(dir, "justfile"), """
    set allow-duplicate-recipes
    import 'loop.just'

    copy-teardown:
        @echo mine
    """)

    assert {"mine\n", 0} = System.cmd("just", ["copy-teardown"], cd: dir)
    assert {out, 0} = System.cmd("just", ["-n", "copy-setup"], cd: dir, stderr_to_stdout: true)
    assert out =~ "mix deps.get"
  end
end
