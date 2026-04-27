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

  alias Jido.Agent
  alias Jido.Agent.StateOp
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.MCP.ClientPool
  alias Jido.MCP.JidoAI.{ProxyGenerator, ProxyRegistry}

  @max_tools 200
  @max_schema_depth 8
  @max_schema_properties 200

  @impl true
  def run(params, context) do
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
      target_agent = context_agent(context)

      target_agent =
        if params[:replace_existing] != false do
          unregister_previous(params[:agent_server], endpoint_id, target_agent)
        else
          target_agent
        end

      {registered, failed, target_agent} =
        register_modules(params[:agent_server], modules, target_agent)

      skipped_failures = Enum.map(skipped, &{&1.tool_name, &1.reason})
      failed = skipped_failures ++ failed

      ProxyRegistry.put(params[:agent_server], endpoint_id, registered)
      ProxyRegistry.subscribe(params[:agent_server], endpoint_id, %{prefix: params[:prefix]})

      result = %{
        endpoint_id: endpoint_id,
        discovered_count: length(tools),
        registered_count: length(registered),
        failed_count: length(failed),
        failed: failed,
        warnings: warnings,
        skipped_count: length(skipped),
        registered_tools: Enum.map(registered, & &1.name())
      }

      with_agent_effect({:ok, result}, target_agent)
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

  defp register_modules(agent_server, modules, nil) do
    jido_ai = Module.concat([Jido, AI])

    Enum.reduce(modules, {[], []}, fn module, {ok, err} ->
      case apply(jido_ai, :register_tool, [agent_server, module]) do
        {:ok, _agent} -> {[module | ok], err}
        {:error, reason} -> {ok, [{module, reason} | err]}
      end
    end)
    |> then(fn {ok, err} -> {Enum.reverse(ok), Enum.reverse(err), nil} end)
  end

  defp register_modules(_agent_server, modules, %Agent{} = agent) do
    Enum.reduce(modules, {agent, [], []}, fn module, {agent, ok, err} ->
      case register_tool_direct(agent, module) do
        {:ok, agent} -> {agent, [module | ok], err}
        {:error, reason} -> {agent, ok, [{module, reason} | err]}
      end
    end)
    |> then(fn {agent, ok, err} -> {Enum.reverse(ok), Enum.reverse(err), agent} end)
  end

  defp unregister_previous(agent_server, endpoint_id, nil) do
    jido_ai = Module.concat([Jido, AI])

    agent_server
    |> ProxyRegistry.get(endpoint_id)
    |> Enum.each(fn module ->
      _ = apply(jido_ai, :unregister_tool, [agent_server, module.name()])
    end)

    _ = ProxyRegistry.delete(agent_server, endpoint_id)
    nil
  end

  defp unregister_previous(agent_server, endpoint_id, %Agent{} = agent) do
    agent =
      agent_server
      |> ProxyRegistry.get(endpoint_id)
      |> Enum.reduce(agent, fn module, acc ->
        case unregister_tool_direct(acc, module.name()) do
          {:ok, agent} -> agent
          {:error, _reason} -> acc
        end
      end)

    _ = ProxyRegistry.delete(agent_server, endpoint_id)
    agent
  end

  defp context_agent(%{agent: %Agent{} = agent}), do: agent
  defp context_agent(_context), do: nil

  defp register_tool_direct(agent, module) do
    jido_ai = Module.concat([Jido, AI])

    if function_exported?(jido_ai, :register_tool_direct, 2) do
      apply(jido_ai, :register_tool_direct, [agent, module])
    else
      {:error, :jido_ai_direct_tool_api_not_available}
    end
  end

  defp unregister_tool_direct(agent, tool_name) do
    jido_ai = Module.concat([Jido, AI])

    if function_exported?(jido_ai, :unregister_tool_direct, 2) do
      apply(jido_ai, :unregister_tool_direct, [agent, tool_name])
    else
      {:error, :jido_ai_direct_tool_api_not_available}
    end
  end

  defp with_agent_effect(response, nil), do: response

  defp with_agent_effect({:ok, result}, %Agent{} = agent) do
    {:ok, result, [StateOp.set_path([StratState.key()], StratState.get(agent, %{}))]}
  end
end
