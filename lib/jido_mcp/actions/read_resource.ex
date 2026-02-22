defmodule Jido.MCP.Actions.ReadResource do
  @moduledoc "Read a resource URI from a configured MCP endpoint."

  use Jido.Action,
    name: "mcp_resources_read",
    description: "Read a resource from an MCP endpoint",
    schema:
      Zoi.object(%{
        endpoint_id: Zoi.any(description: "Configured endpoint id") |> Zoi.optional(),
        uri: Zoi.string(description: "Resource URI"),
        timeout: Zoi.integer(description: "Request timeout in milliseconds") |> Zoi.optional()
      })

  alias Jido.MCP.Actions.Helpers

  @impl true
  def run(params, context) do
    with {:ok, endpoint_id} <- Helpers.resolve_endpoint_id(params, context) do
      opts = maybe_put([], :timeout, params[:timeout])
      Jido.MCP.read_resource(endpoint_id, params[:uri], opts)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
