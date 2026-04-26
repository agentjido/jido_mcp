defmodule Jido.MCP.Actions.RegisterEndpoint do
  @moduledoc "Register a runtime MCP endpoint definition."

  use Jido.Action,
    name: "mcp_endpoint_register",
    description: "Register a runtime MCP endpoint",
    schema:
      Zoi.object(%{
        endpoint_id: Zoi.any(description: "Endpoint id (atom/string)"),
        endpoint:
          Zoi.map(
            description:
              "Endpoint attrs map (transport, client_info, protocol_version, capabilities, timeouts)"
          )
      })

  @impl true
  def run(params, _context) do
    with {:ok, endpoint_id} <- normalize_endpoint_id(params[:endpoint_id]),
         {:ok, endpoint} <- Jido.MCP.Endpoint.new(endpoint_id, params[:endpoint] || %{}),
         {:ok, registered_endpoint} <- Jido.MCP.register_endpoint(endpoint) do
      {:ok,
       %{
         status: :ok,
         endpoint_id: registered_endpoint.id,
         registered: true
       }}
    end
  end

  defp normalize_endpoint_id(value) when is_atom(value), do: {:ok, value}

  defp normalize_endpoint_id(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, :invalid_endpoint_id}
      true -> {:ok, String.to_atom(value)}
    end
  end

  defp normalize_endpoint_id(_), do: {:error, :invalid_endpoint_id}
end
