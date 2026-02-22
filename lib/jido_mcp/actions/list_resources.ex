defmodule Jido.MCP.Actions.ListResources do
  @moduledoc "List resources for a configured MCP endpoint."

  use Jido.Action,
    name: "mcp_resources_list",
    description: "List resources from an MCP endpoint",
    schema:
      Zoi.object(%{
        endpoint_id: Zoi.any(description: "Configured endpoint id") |> Zoi.optional(),
        timeout: Zoi.integer(description: "Request timeout in milliseconds") |> Zoi.optional(),
        cursor: Zoi.string(description: "Pagination cursor") |> Zoi.optional()
      })

  alias Jido.MCP.Actions.Helpers

  @impl true
  def run(params, context) do
    with {:ok, endpoint_id} <- Helpers.resolve_endpoint_id(params, context) do
      opts =
        []
        |> maybe_put(:timeout, params[:timeout])
        |> maybe_put(:cursor, params[:cursor])

      Jido.MCP.list_resources(endpoint_id, opts)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
