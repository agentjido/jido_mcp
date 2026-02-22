defmodule Jido.MCP.Actions.RefreshEndpoint do
  @moduledoc "Restart and refresh a configured MCP endpoint client."

  use Jido.Action,
    name: "mcp_endpoint_refresh",
    description: "Refresh endpoint client lifecycle and metadata cache",
    schema:
      Zoi.object(%{
        endpoint_id: Zoi.any(description: "Configured endpoint id")
      })

  alias Jido.MCP.Actions.Helpers

  @impl true
  def run(params, context) do
    with {:ok, endpoint_id} <- Helpers.resolve_endpoint_id(params, context) do
      Jido.MCP.refresh_endpoint(endpoint_id)
    end
  end
end
