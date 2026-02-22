defmodule Jido.MCP.Actions.GetPrompt do
  @moduledoc "Get a prompt by name from a configured MCP endpoint."

  use Jido.Action,
    name: "mcp_prompts_get",
    description: "Get a prompt from an MCP endpoint",
    schema:
      Zoi.object(%{
        endpoint_id: Zoi.any(description: "Configured endpoint id") |> Zoi.optional(),
        prompt_name: Zoi.string(description: "Prompt name"),
        arguments: Zoi.map(description: "Prompt arguments") |> Zoi.default(%{}),
        timeout: Zoi.integer(description: "Request timeout in milliseconds") |> Zoi.optional()
      })

  alias Jido.MCP.Actions.Helpers

  @impl true
  def run(params, context) do
    with {:ok, endpoint_id} <- Helpers.resolve_endpoint_id(params, context) do
      opts = maybe_put([], :timeout, params[:timeout])
      Jido.MCP.get_prompt(endpoint_id, params[:prompt_name], params[:arguments] || %{}, opts)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
