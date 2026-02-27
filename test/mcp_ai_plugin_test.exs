defmodule Jido.MCP.JidoAI.Plugins.MCPAITest do
  use ExUnit.Case, async: true

  alias Jido.MCP.JidoAI.Plugins.MCPAI

  test "mount enables plugin and exposes signal routes" do
    assert {:ok, %{enabled: true}} = MCPAI.mount(nil, %{})

    routes = MCPAI.signal_routes(%{})
    assert {"mcp.ai.sync_tools", Jido.MCP.JidoAI.Actions.SyncToolsToAgent} in routes
    assert {"mcp.ai.unsync_tools", Jido.MCP.JidoAI.Actions.UnsyncToolsFromAgent} in routes
  end

  test "handle_signal and transform_result are pass-through" do
    assert {:ok, :continue} = MCPAI.handle_signal(%{}, %{})
    assert MCPAI.transform_result(:action, {:ok, :value}, %{}) == {:ok, :value}
  end
end
