defmodule Jido.MCP.JidoAI.RuntimeSync do
  @moduledoc false

  alias Jido.MCP.JidoAI.Actions.{SyncToolsToAgent, UnsyncToolsFromAgent}
  alias Jido.MCP.JidoAI.ProxyRegistry

  @type sync_result :: %{
          status: :ok | :warning | :error,
          operation: :sync | :unsync,
          endpoint_id: atom(),
          attempted: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          results: [map()]
        }

  @spec on_endpoint_registered(atom()) :: sync_result()
  def on_endpoint_registered(endpoint_id) when is_atom(endpoint_id) do
    sync_subscribers(endpoint_id, :sync)
  end

  @spec on_endpoint_refreshed(atom()) :: sync_result()
  def on_endpoint_refreshed(endpoint_id) when is_atom(endpoint_id) do
    sync_subscribers(endpoint_id, :sync)
  end

  @spec before_endpoint_unregistered(atom()) :: sync_result()
  def before_endpoint_unregistered(endpoint_id) when is_atom(endpoint_id) do
    sync_subscribers(endpoint_id, :unsync)
  end

  @spec sync_endpoint_to_agent(term(), term(), map()) :: sync_result()
  def sync_endpoint_to_agent(endpoint_id, agent_server, options \\ %{}) when is_map(options) do
    to_status(endpoint_id, :sync, [sync_one(endpoint_id, agent_server, options)])
  end

  @spec unsync_endpoint_from_agent(term(), term()) :: sync_result()
  def unsync_endpoint_from_agent(endpoint_id, agent_server) do
    to_status(endpoint_id, :unsync, [unsync_one(endpoint_id, agent_server)])
  end

  defp sync_subscribers(endpoint_id, operation) do
    results =
      endpoint_id
      |> ProxyRegistry.subscribers_for()
      |> Enum.map(fn %{agent_server: agent_server, options: options} ->
        case operation do
          :sync -> sync_one(endpoint_id, agent_server, options)
          :unsync -> unsync_one(endpoint_id, agent_server)
        end
      end)

    to_status(endpoint_id, operation, results)
  end

  defp sync_one(endpoint_id, agent_server, options) do
    params = %{
      endpoint_id: endpoint_id,
      agent_server: agent_server,
      prefix: Map.get(options, :prefix),
      replace_existing: true
    }

    case SyncToolsToAgent.run(params, %{}) do
      {:ok, result} -> %{agent_server: agent_server, status: :ok, result: result}
      {:error, reason} -> %{agent_server: agent_server, status: :error, reason: reason}
    end
  end

  defp unsync_one(endpoint_id, agent_server) do
    case UnsyncToolsFromAgent.run(%{endpoint_id: endpoint_id, agent_server: agent_server}, %{}) do
      {:ok, result} -> %{agent_server: agent_server, status: :ok, result: result}
      {:error, reason} -> %{agent_server: agent_server, status: :error, reason: reason}
    end
  end

  defp to_status(endpoint_id, operation, results) do
    attempted = length(results)
    succeeded = Enum.count(results, &(&1.status == :ok))
    failed = attempted - succeeded

    status =
      cond do
        failed == 0 -> :ok
        succeeded == 0 -> :error
        true -> :warning
      end

    %{
      status: status,
      operation: operation,
      endpoint_id: normalize_endpoint_id(endpoint_id),
      attempted: attempted,
      succeeded: succeeded,
      failed: failed,
      results: results
    }
  end

  defp normalize_endpoint_id(endpoint_id) when is_atom(endpoint_id), do: endpoint_id
  defp normalize_endpoint_id(_), do: :unknown
end
