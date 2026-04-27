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

  alias Jido.MCP.ClientPool
  alias Jido.MCP.JidoAI.{ProxyGenerator, ProxyRegistry}

  @max_tools 200
  @max_schema_depth 8
  @max_schema_properties 200

  @impl true
  def run(params, _context) do
    with :ok <- ensure_jido_ai_loaded(),
         {:ok, endpoint_id} <- ClientPool.resolve_endpoint_id(params[:endpoint_id]),
         {:ok, response} <- Jido.MCP.list_tools(endpoint_id),
         tools when is_list(tools) <- get_in(response, [:data, "tools"]) || [],
         :ok <- ensure_tool_limit(tools),
         {:ok, modules, warnings, skipped} <-
           ProxyGenerator.build_modules(endpoint_id, tools,
             prefix: params[:prefix],
             max_schema_depth: @max_schema_depth,
             max_schema_properties: @max_schema_properties
           ) do
      if params[:replace_existing] != false do
        _ = unregister_previous(params[:agent_server], endpoint_id)
      end

      {registered, failed} = register_modules(params[:agent_server], modules)
      skipped_failures = Enum.map(skipped, &{&1.tool_name, &1.reason})
      failed = skipped_failures ++ failed

      ProxyRegistry.put(params[:agent_server], endpoint_id, registered)

      {:ok,
       %{
         endpoint_id: endpoint_id,
         discovered_count: length(tools),
         registered_count: length(registered),
         failed_count: length(failed),
         failed: failed,
         warnings: warnings,
         skipped_count: length(skipped),
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

  defp ensure_tool_limit(tools) when length(tools) > @max_tools do
    {:error, {:tool_limit_exceeded, %{max_tools: @max_tools, discovered: length(tools)}}}
  end

  defp ensure_tool_limit(_tools), do: :ok

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

    agent_server
    |> ProxyRegistry.get(endpoint_id)
    |> Enum.each(fn module ->
      _ = apply(jido_ai, :unregister_tool, [agent_server, module.name()])
    end)

    _ = ProxyRegistry.delete(agent_server, endpoint_id)
    :ok
  end
end
