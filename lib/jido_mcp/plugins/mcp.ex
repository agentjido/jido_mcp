require Jido.MCP.Actions.ListTools
require Jido.MCP.Actions.CallTool
require Jido.MCP.Actions.ListResources
require Jido.MCP.Actions.ListResourceTemplates
require Jido.MCP.Actions.ReadResource
require Jido.MCP.Actions.ListPrompts
require Jido.MCP.Actions.GetPrompt
require Jido.MCP.Actions.RefreshEndpoint

defmodule Jido.MCP.Plugins.MCP do
  @moduledoc """
  Plugin exposing MCP consume-side routes (tools/resources/prompts/endpoints).
  """

  use Jido.Plugin,
    name: "mcp",
    state_key: :mcp,
    actions: [
      Jido.MCP.Actions.ListTools,
      Jido.MCP.Actions.CallTool,
      Jido.MCP.Actions.ListResources,
      Jido.MCP.Actions.ListResourceTemplates,
      Jido.MCP.Actions.ReadResource,
      Jido.MCP.Actions.ListPrompts,
      Jido.MCP.Actions.GetPrompt,
      Jido.MCP.Actions.RefreshEndpoint
    ],
    description: "Model Context Protocol integration",
    category: "mcp",
    tags: ["mcp", "tools", "resources", "prompts"],
    vsn: "0.1.0"

  @impl Jido.Plugin
  def mount(_agent, config) do
    {:ok,
     %{
       default_endpoint: Map.get(config, :default_endpoint),
       allowed_endpoints: normalize_allowed_endpoints(Map.get(config, :allowed_endpoints))
     }}
  end

  @impl Jido.Plugin
  def signal_routes(_config) do
    [
      {"mcp.tools.list", Jido.MCP.Actions.ListTools},
      {"mcp.tools.call", Jido.MCP.Actions.CallTool},
      {"mcp.resources.list", Jido.MCP.Actions.ListResources},
      {"mcp.resources.templates.list", Jido.MCP.Actions.ListResourceTemplates},
      {"mcp.resources.read", Jido.MCP.Actions.ReadResource},
      {"mcp.prompts.list", Jido.MCP.Actions.ListPrompts},
      {"mcp.prompts.get", Jido.MCP.Actions.GetPrompt},
      {"mcp.endpoint.refresh", Jido.MCP.Actions.RefreshEndpoint}
    ]
  end

  @impl Jido.Plugin
  def handle_signal(_signal, _context), do: {:ok, :continue}

  @impl Jido.Plugin
  def transform_result(_action, result, _context), do: result

  defp normalize_allowed_endpoints(nil), do: nil

  defp normalize_allowed_endpoints(values) when is_list(values) do
    Enum.map(values, fn
      value when is_atom(value) -> value
      value when is_binary(value) -> String.to_atom(value)
    end)
  end

  defp normalize_allowed_endpoints(_), do: nil
end
