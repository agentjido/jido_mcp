defmodule Jido.MCP.Actions.SetDefaultEndpoint do
  @moduledoc "Set or clear the MCP plugin default endpoint at runtime."

  use Jido.Action,
    name: "mcp_endpoint_default_set",
    description: "Set default endpoint for MCP actions when endpoint_id is omitted",
    schema:
      Zoi.object(%{
        endpoint_id:
          Zoi.any(description: "Endpoint id (atom/string), or nil to clear default")
          |> Zoi.optional()
      })

  alias Jido.MCP.Actions.Helpers

  @impl true
  def run(params, context) do
    case first_present([params[:endpoint_id], params["endpoint_id"]]) do
      nil ->
        {:ok, %{mcp: %{default_endpoint: nil}}}

      endpoint_id ->
        with {:ok, endpoint_id} <- Helpers.normalize_endpoint_id(endpoint_id),
             :ok <- Helpers.validate_allowed_endpoint(endpoint_id, context) do
          {:ok, %{mcp: %{default_endpoint: endpoint_id}}}
        end
    end
  end

  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))
end
