defmodule Jido.MCP.Actions.CallTool do
  @moduledoc "Call a tool on a configured MCP endpoint."

  use Jido.Action,
    name: "mcp_tools_call",
    description: "Call a tool on an MCP endpoint",
    schema:
      Zoi.object(%{
        endpoint_id: Zoi.any(description: "Configured endpoint id") |> Zoi.optional(),
        tool_name: Zoi.string(description: "MCP tool name"),
        arguments: Zoi.map(description: "Tool call arguments") |> Zoi.default(%{}),
        timeout: Zoi.integer(description: "Request timeout in milliseconds") |> Zoi.optional()
      })

  alias Jido.MCP.Actions.Helpers

  @impl true
  def run(params, context) do
    with {:ok, endpoint_id} <- Helpers.resolve_endpoint_id(params, context) do
      opts = maybe_put([], :timeout, params[:timeout])
      Jido.MCP.call_tool(endpoint_id, params[:tool_name], params[:arguments] || %{}, opts)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
