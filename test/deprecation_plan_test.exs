defmodule Jido.MCP.DeprecationPlanTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  test "the prepared deprecation plan remains inactive" do
    guide = File.read!(Path.join(@root, "guides/deprecation_plan.md"))
    readme = File.read!(Path.join(@root, "README.md"))
    mix_project = File.read!(Path.join(@root, "mix.exs"))

    assert guide =~ "Status: Draft and inactive"
    assert guide =~ "No support window is active"
    assert guide =~ "explicit retirement approval"
    assert readme =~ "It is not yet deprecated on Hex"
    refute mix_project =~ "deprecated:"
    refute mix_project =~ "retired:"
  end
end
