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

  alias Jido.Agent
  alias Jido.Agent.StateOp
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.MCP.ClientPool
  alias Jido.MCP.JidoAI.ProxyRegistry

  @impl true
  def run(params, context) do
    with :ok <- ensure_jido_ai_loaded(),
         {:ok, endpoint_id} <- ClientPool.resolve_endpoint_id(params[:endpoint_id]) do
      modules = ProxyRegistry.get(params[:agent_server], endpoint_id)
      target_agent = context_agent(context)

      {removed, failed, target_agent} =
        unregister_modules(params[:agent_server], modules, target_agent)

      deleted_modules = ProxyRegistry.delete(params[:agent_server], endpoint_id)
      ProxyRegistry.unsubscribe(params[:agent_server], endpoint_id)
      {purged, retained, purge_failed} = cleanup_deleted_modules(deleted_modules)

      result = %{
        endpoint_id: endpoint_id,
        removed_count: length(removed),
        failed_count: length(failed),
        removed_tools: Enum.reverse(removed),
        failed: Enum.reverse(failed),
        purged_count: length(purged),
        retained_count: length(retained),
        purge_failed_count: length(purge_failed),
        purged_modules: Enum.reverse(purged),
        retained_modules: Enum.reverse(retained),
        purge_failed: Enum.reverse(purge_failed)
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

  defp unregister_modules(agent_server, modules, nil) do
    jido_ai = Module.concat([Jido, AI])

    Enum.reduce(modules, {[], []}, fn module, {ok, err} ->
      case apply(jido_ai, :unregister_tool, [agent_server, module.name()]) do
        {:ok, _agent} -> {[module.name() | ok], err}
        {:error, reason} -> {ok, [{module.name(), reason} | err]}
      end
    end)
    |> then(fn {ok, err} -> {ok, err, nil} end)
  end

  defp unregister_modules(_agent_server, modules, %Agent{} = agent) do
    Enum.reduce(modules, {[], [], agent}, fn module, {ok, err, agent} ->
      case unregister_tool_direct(agent, module.name()) do
        {:ok, agent} -> {[module.name() | ok], err, agent}
        {:error, reason} -> {ok, [{module.name(), reason} | err], agent}
      end
    end)
  end

  defp cleanup_deleted_modules(modules) do
    Enum.reduce(modules, {[], [], []}, fn module, {purged, retained, failed} ->
      cond do
        ProxyRegistry.module_in_use?(module) ->
          {purged, [module | retained], failed}

        true ->
          case purge_module(module) do
            :ok -> {[module | purged], retained, failed}
            {:error, reason} -> {purged, retained, [{module, reason} | failed]}
          end
      end
    end)
  end

  defp purge_module(module) when is_atom(module) do
    if proxy_module?(module) and Code.ensure_loaded?(module) do
      _ = :code.purge(module)
      _ = :code.delete(module)
      :ok
    else
      :ok
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  defp proxy_module?(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Jido.MCP.JidoAI.Proxy.")
  end

  defp context_agent(%{agent: %Agent{} = agent}), do: agent
  defp context_agent(_context), do: nil

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
