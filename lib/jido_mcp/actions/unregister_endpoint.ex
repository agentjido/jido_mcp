defmodule Jido.MCP.Actions.UnregisterEndpoint do
  @moduledoc "Unregister a runtime MCP endpoint definition."

  use Jido.Action,
    name: "mcp_endpoint_unregister",
    description: "Unregister a runtime MCP endpoint",
    schema:
      Zoi.object(%{
        endpoint_id: Zoi.any(description: "Configured endpoint id")
      })

  alias Jido.MCP.Actions.Helpers

  @impl true
  def run(params, _context) do
    with {:ok, endpoint_id} <- Helpers.normalize_endpoint_id(params[:endpoint_id]) do
      Jido.MCP.unregister_endpoint(endpoint_id)
    end
  end
end
