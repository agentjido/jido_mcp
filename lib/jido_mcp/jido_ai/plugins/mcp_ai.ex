require Jido.MCP.JidoAI.Actions.SyncToolsToAgent
require Jido.MCP.JidoAI.Actions.UnsyncToolsFromAgent

defmodule Jido.MCP.JidoAI.Plugins.MCPAI do
  @moduledoc """
  Plugin that exposes MCP tool sync/unsync routes for running Jido.AI agents.
  """

  use Jido.Plugin,
    name: "mcp_ai",
    state_key: :mcp_ai,
    actions: [
      Jido.MCP.JidoAI.Actions.SyncToolsToAgent,
      Jido.MCP.JidoAI.Actions.UnsyncToolsFromAgent
    ],
    description: "MCP to Jido.AI runtime tool synchronization",
    category: "mcp",
    tags: ["mcp", "jido_ai", "tool-sync"],
    vsn: "0.1.0"

  @impl Jido.Plugin
  def mount(_agent, _config), do: {:ok, %{enabled: true}}

  @impl Jido.Plugin
  def signal_routes(_config) do
    [
      {"mcp.ai.sync_tools", Jido.MCP.JidoAI.Actions.SyncToolsToAgent},
      {"mcp.ai.unsync_tools", Jido.MCP.JidoAI.Actions.UnsyncToolsFromAgent}
    ]
  end

  @impl Jido.Plugin
  def handle_signal(_signal, _context), do: {:ok, :continue}

  @impl Jido.Plugin
  def transform_result(_action, result, _context), do: result
end
