# The CodeMySpec loop's recipes. Installed by `mix client_utils.gen.loop_recipes`,
# which overwrites this file: do not edit it. To change one for this project,
# define a recipe of the same name in the justfile that imports this.

# Run once in a work copy the loop has just cut, before any step.
copy-setup:
    mix deps.get

# Run in a work copy before the loop removes it. Take down what copy-setup or
# the checks made for this copy alone; never anything another copy shares.
copy-teardown:
    @true

# Every suite. The loop reads the SARIF files left in dir.
run dir:
    env MIX_ENV=test mix client_utils.sarif "{{dir}}/exunit.sarif" -- mix test
    env MIX_ENV=test mix client_utils.sarif "{{dir}}/spex.sarif" -- mix spex

# Everything that must hold before work lands.
certify dir:
    env MIX_ENV=test mix client_utils.sarif "{{dir}}/format.sarif" -- mix format --check-formatted
    env MIX_ENV=test mix client_utils.sarif "{{dir}}/compiler.sarif" -- mix compile --warnings-as-errors
    env MIX_ENV=test mix client_utils.sarif "{{dir}}/exunit.sarif" -- mix test
    env MIX_ENV=test mix client_utils.sarif "{{dir}}/spex.sarif" -- mix spex
