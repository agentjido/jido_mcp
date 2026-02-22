defmodule Jido.MCP.JidoAI.Actions.SyncToolsToAgent do
  @moduledoc """
  Sync MCP tools from an endpoint into a running `Jido.AI.Agent` as proxy Jido actions.
  """

  use Jido.Action,
    name: "mcp_ai_sync_tools",
    description: "Sync MCP tools to a running Jido.AI agent",
    schema:
      Zoi.object(%{
        endpoint_id: Zoi.any(description: "Configured MCP endpoint id (atom or string)"),
        agent_server: Zoi.any(description: "PID or registered name of the running Jido.AI agent"),
        prefix:
          Zoi.string(description: "Optional local tool name prefix")
          |> Zoi.optional(),
        replace_existing:
          Zoi.boolean(
            description: "Unregister previously synced tools for this endpoint before syncing"
          )
          |> Zoi.default(true)
      })

  alias Jido.MCP.JidoAI.{ProxyGenerator, ProxyRegistry}

  @impl true
  def run(params, _context) do
    with :ok <- ensure_jido_ai_loaded(),
         {:ok, endpoint_id} <- normalize_endpoint_id(params[:endpoint_id]),
         {:ok, response} <- Jido.MCP.list_tools(endpoint_id),
         tools when is_list(tools) <- get_in(response, [:data, "tools"]) || [],
         {:ok, modules, warnings} <-
           ProxyGenerator.build_modules(endpoint_id, tools, prefix: params[:prefix]) do
      if params[:replace_existing] != false do
        _ = unregister_previous(params[:agent_server], endpoint_id)
      end

      {registered, failed} = register_modules(params[:agent_server], modules)
      ProxyRegistry.put(endpoint_id, registered)

      {:ok,
       %{
         endpoint_id: endpoint_id,
         discovered_count: length(tools),
         registered_count: length(registered),
         failed_count: length(failed),
         failed: failed,
         warnings: warnings,
         registered_tools: Enum.map(registered, & &1.name())
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

  defp register_modules(agent_server, modules) do
    jido_ai = Module.concat([Jido, AI])

    Enum.reduce(modules, {[], []}, fn module, {ok, err} ->
      case apply(jido_ai, :register_tool, [agent_server, module]) do
        {:ok, _agent} -> {[module | ok], err}
        {:error, reason} -> {ok, [{module, reason} | err]}
      end
    end)
    |> then(fn {ok, err} -> {Enum.reverse(ok), Enum.reverse(err)} end)
  end

  defp unregister_previous(agent_server, endpoint_id) do
    jido_ai = Module.concat([Jido, AI])

    endpoint_id
    |> ProxyRegistry.get()
    |> Enum.each(fn module ->
      _ = apply(jido_ai, :unregister_tool, [agent_server, module.name()])
    end)

    ProxyRegistry.delete(endpoint_id)
    :ok
  end
end
