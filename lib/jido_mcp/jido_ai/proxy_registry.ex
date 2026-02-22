defmodule Jido.MCP.JidoAI.ProxyRegistry do
  @moduledoc false

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @spec put(atom(), [module()]) :: :ok
  def put(endpoint_id, modules) when is_atom(endpoint_id) and is_list(modules) do
    Agent.update(__MODULE__, &Map.put(&1, endpoint_id, modules))
  end

  @spec get(atom()) :: [module()]
  def get(endpoint_id) when is_atom(endpoint_id) do
    Agent.get(__MODULE__, &Map.get(&1, endpoint_id, []))
  end

  @spec delete(atom()) :: :ok
  def delete(endpoint_id) when is_atom(endpoint_id) do
    Agent.update(__MODULE__, &Map.delete(&1, endpoint_id))
  end
end
