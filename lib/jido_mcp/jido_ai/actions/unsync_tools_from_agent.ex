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

  alias Jido.MCP.ClientPool
  alias Jido.MCP.JidoAI.ProxyRegistry

  @impl true
  def run(params, _context) do
    with :ok <- ensure_jido_ai_loaded(),
         {:ok, endpoint_id} <- ClientPool.resolve_endpoint_id(params[:endpoint_id]) do
      jido_ai = Module.concat([Jido, AI])
      modules = ProxyRegistry.get(params[:agent_server], endpoint_id)

      {removed, failed} =
        Enum.reduce(modules, {[], []}, fn module, {ok, err} ->
          case apply(jido_ai, :unregister_tool, [params[:agent_server], module.name()]) do
            {:ok, _agent} -> {[module.name() | ok], err}
            {:error, reason} -> {ok, [{module.name(), reason} | err]}
          end
        end)

      deleted_modules = ProxyRegistry.delete(params[:agent_server], endpoint_id)
      ProxyRegistry.unsubscribe(params[:agent_server], endpoint_id)
      {purged, retained, purge_failed} = cleanup_deleted_modules(deleted_modules)

      {:ok,
       %{
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
end
