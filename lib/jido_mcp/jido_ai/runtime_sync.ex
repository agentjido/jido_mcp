defmodule Jido.MCP.JidoAI.RuntimeSync do
  @moduledoc false

  alias Jido.MCP.JidoAI.Actions.{SyncToolsToAgent, UnsyncToolsFromAgent}
  alias Jido.MCP.JidoAI.ProxyRegistry

  @spec on_endpoint_registered(atom()) :: %{synced_count: non_neg_integer(), failed: [term()]}
  def on_endpoint_registered(endpoint_id) when is_atom(endpoint_id) do
    ProxyRegistry.opted_in_agents()
    |> Enum.reduce(%{synced_count: 0, failed: []}, fn %{
                                                        agent_server: agent_server,
                                                        options: options
                                                      },
                                                      acc ->
      params = %{
        endpoint_id: endpoint_id,
        agent_server: agent_server,
        prefix: Map.get(options, :prefix),
        replace_existing: true
      }

      case SyncToolsToAgent.run(params, %{}) do
        {:ok, _result} -> %{acc | synced_count: acc.synced_count + 1}
        {:error, reason} -> %{acc | failed: [{agent_server, reason} | acc.failed]}
      end
    end)
    |> then(fn result -> %{result | failed: Enum.reverse(result.failed)} end)
  end

  @spec before_endpoint_unregistered(atom()) ::
          %{unsynced_count: non_neg_integer(), failed: [term()]}
  def before_endpoint_unregistered(endpoint_id) when is_atom(endpoint_id) do
    ProxyRegistry.opted_in_agents()
    |> Enum.reduce(%{unsynced_count: 0, failed: []}, fn %{agent_server: agent_server}, acc ->
      case UnsyncToolsFromAgent.run(%{endpoint_id: endpoint_id, agent_server: agent_server}, %{}) do
        {:ok, _result} -> %{acc | unsynced_count: acc.unsynced_count + 1}
        {:error, reason} -> %{acc | failed: [{agent_server, reason} | acc.failed]}
      end
    end)
    |> then(fn result -> %{result | failed: Enum.reverse(result.failed)} end)
  end
end
