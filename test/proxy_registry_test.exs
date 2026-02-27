defmodule Jido.MCP.JidoAI.ProxyRegistryTest do
  use ExUnit.Case, async: false

  alias Jido.MCP.JidoAI.ProxyRegistry

  defmodule ToolA do
    use Jido.Action,
      name: "tool_a",
      schema: []

    @impl true
    def run(_params, _context), do: {:ok, %{}}
  end

  defmodule ToolB do
    use Jido.Action,
      name: "tool_b",
      schema: []

    @impl true
    def run(_params, _context), do: {:ok, %{}}
  end

  setup do
    Agent.update(ProxyRegistry, fn _ -> %{} end)
    :ok
  end

  test "stores registrations per agent+endpoint key" do
    ProxyRegistry.put(:agent_one, :github, [ToolA])
    ProxyRegistry.put(:agent_two, :github, [ToolB])

    assert ProxyRegistry.get(:agent_one, :github) == [ToolA]
    assert ProxyRegistry.get(:agent_two, :github) == [ToolB]
  end

  test "delete returns removed modules and removes only that key" do
    ProxyRegistry.put(:agent_one, :github, [ToolA])
    ProxyRegistry.put(:agent_two, :github, [ToolA, ToolB])

    assert ProxyRegistry.delete(:agent_one, :github) == [ToolA]
    assert ProxyRegistry.get(:agent_one, :github) == []
    assert ProxyRegistry.get(:agent_two, :github) == [ToolA, ToolB]
  end

  test "module_in_use?/1 reflects cross-agent references" do
    ProxyRegistry.put(:agent_one, :github, [ToolA])
    ProxyRegistry.put(:agent_two, :github, [ToolA, ToolB])

    assert ProxyRegistry.module_in_use?(ToolA)
    assert ProxyRegistry.module_in_use?(ToolB)

    _ = ProxyRegistry.delete(:agent_two, :github)
    assert ProxyRegistry.module_in_use?(ToolA)
    refute ProxyRegistry.module_in_use?(ToolB)
  end
end
