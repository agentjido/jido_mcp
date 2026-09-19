defmodule Jido.MCP.DeprecationPlanTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  test "the package deprecation is explicit" do
    guide = File.read!(Path.join(@root, "guides/deprecation_plan.md"))
    readme = File.read!(Path.join(@root, "README.md"))
    mix_project = File.read!(Path.join(@root, "mix.exs"))

    assert guide =~ "Status: Active"
    assert guide =~ "There is no support window"
    assert guide =~ "deprecated"
    assert readme =~ "`jido_mcp` is deprecated"
    refute mix_project =~ "deprecated:"
    refute mix_project =~ "retired:"
  end
end
