defmodule Jido.MCP.JidoAI.Actions.UnsyncToolsFromAgent do
  @moduledoc """
  Remove previously synced MCP proxy tools from a running `Jido.AI.Agent`.
  """

  use Jido.Action,
    name: "mcp_ai_unsync_tools",
    description: "Unsync MCP tools from a running Jido.AI agent",
    schema:
      Zoi.object(%{
        endpoint_id: Zoi.any(description: "Configured MCP endpoint id (atom or string)"),
        agent_server: Zoi.any(description: "PID or registered name of the running Jido.AI agent")
      })

  alias Jido.MCP.JidoAI.ProxyRegistry

  @impl true
  def run(params, _context) do
    with :ok <- ensure_jido_ai_loaded(),
         {:ok, endpoint_id} <- normalize_endpoint_id(params[:endpoint_id]) do
      jido_ai = Module.concat([Jido, AI])
      modules = ProxyRegistry.get(endpoint_id)

      {removed, failed} =
        Enum.reduce(modules, {[], []}, fn module, {ok, err} ->
          case apply(jido_ai, :unregister_tool, [params[:agent_server], module.name()]) do
            {:ok, _agent} -> {[module.name() | ok], err}
            {:error, reason} -> {ok, [{module.name(), reason} | err]}
          end
        end)

      ProxyRegistry.delete(endpoint_id)

      {:ok,
       %{
         endpoint_id: endpoint_id,
         removed_count: length(removed),
         failed_count: length(failed),
         removed_tools: Enum.reverse(removed),
         failed: Enum.reverse(failed)
       }}
    end
  end

  defp ensure_jido_ai_loaded do
    module = Module.concat([Jido, AI])

    if Code.ensure_loaded?(module) do
      :ok
    else
      {:error, :jido_ai_not_available}
    end
  end

  defp normalize_endpoint_id(id) when is_atom(id), do: {:ok, id}
  defp normalize_endpoint_id(id) when is_binary(id), do: {:ok, String.to_atom(id)}
  defp normalize_endpoint_id(_), do: {:error, :invalid_endpoint_id}
end
