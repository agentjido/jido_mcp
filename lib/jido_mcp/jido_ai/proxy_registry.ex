defmodule Jido.MCP.JidoAI.ProxyRegistry do
  @moduledoc false

  use Agent

  @type agent_identity :: {:pid, pid()} | {:name, term()}
  @type registry_key :: {agent_identity(), atom()}
  @type registry_state :: %{
          optional(:entries) => %{optional(registry_key()) => [module()]},
          optional(:opted_in) => %{
            optional(agent_identity()) => %{agent_server: term(), options: map()}
          }
        }

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @spec put(term(), atom(), [module()]) :: :ok
  def put(agent_server, endpoint_id, modules)
      when is_atom(endpoint_id) and is_list(modules) do
    key = key_for(agent_server, endpoint_id)

    Agent.update(__MODULE__, fn state ->
      state
      |> normalize_state()
      |> put_in([:entries, key], modules)
    end)
  end

  @spec get(term(), atom()) :: [module()]
  def get(agent_server, endpoint_id) when is_atom(endpoint_id) do
    key = key_for(agent_server, endpoint_id)

    Agent.get(__MODULE__, fn state ->
      state
      |> normalize_state()
      |> get_in([:entries, key])
      |> Kernel.||([])
    end)
  end

  @spec delete(term(), atom()) :: [module()]
  def delete(agent_server, endpoint_id) when is_atom(endpoint_id) do
    key = key_for(agent_server, endpoint_id)

    Agent.get_and_update(__MODULE__, fn state ->
      normalized = normalize_state(state)
      removed = get_in(normalized, [:entries, key]) || []
      {removed, update_in(normalized, [:entries], &Map.delete(&1, key))}
    end)
  end

  @spec module_in_use?(module()) :: boolean()
  def module_in_use?(module) when is_atom(module) do
    Agent.get(__MODULE__, fn state ->
      state
      |> normalize_state()
      |> Map.fetch!(:entries)
      |> Enum.any?(fn {_key, modules} -> module in modules end)
    end)
  end

  @spec opt_in(term(), map()) :: :ok
  def opt_in(agent_server, options \\ %{}) when is_map(options) do
    identity = agent_identity(agent_server)

    Agent.update(__MODULE__, fn state ->
      state
      |> normalize_state()
      |> put_in([:opted_in, identity], %{agent_server: agent_server, options: options})
    end)
  end

  @spec opt_out(term()) :: :ok
  def opt_out(agent_server) do
    identity = agent_identity(agent_server)

    Agent.update(__MODULE__, fn state ->
      state
      |> normalize_state()
      |> update_in([:opted_in], &Map.delete(&1, identity))
    end)
  end

  @spec opted_in_agents() :: [%{agent_server: term(), options: map()}]
  def opted_in_agents do
    Agent.get(__MODULE__, fn state ->
      state
      |> normalize_state()
      |> Map.fetch!(:opted_in)
      |> Map.values()
    end)
  end

  @spec key_for(term(), atom()) :: registry_key()
  def key_for(agent_server, endpoint_id) when is_atom(endpoint_id) do
    {agent_identity(agent_server), endpoint_id}
  end

  @spec agent_identity(term()) :: agent_identity()
  def agent_identity(agent_server) when is_pid(agent_server), do: {:pid, agent_server}
  def agent_identity(agent_server), do: {:name, agent_server}

  @spec entries() :: %{optional(registry_key()) => [module()]}
  def entries do
    Agent.get(__MODULE__, fn state ->
      state
      |> normalize_state()
      |> Map.fetch!(:entries)
    end)
  end

  @spec normalize_state(term()) :: registry_state()
  defp normalize_state(%{entries: entries, opted_in: opted_in})
       when is_map(entries) and is_map(opted_in) do
    %{entries: entries, opted_in: opted_in}
  end

  defp normalize_state(state) when is_map(state) do
    %{entries: state, opted_in: %{}}
  end

  defp normalize_state(_), do: %{entries: %{}, opted_in: %{}}
end
