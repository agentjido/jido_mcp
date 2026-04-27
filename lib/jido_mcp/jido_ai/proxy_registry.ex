defmodule Jido.MCP.JidoAI.ProxyRegistry do
  @moduledoc false

  use Agent

  @type agent_identity :: {:pid, pid()} | {:name, term()}
  @type registry_key :: {agent_identity(), atom()}

  @type subscription :: %{
          agent_server: term(),
          options: map()
        }

  @type registry_state :: %{
          entries: %{optional(registry_key()) => [module()]},
          subscriptions: %{optional(atom()) => %{optional(agent_identity()) => subscription()}}
        }

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> initial_state() end, name: __MODULE__)
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

  @spec subscribe(term(), atom(), map()) :: :ok
  def subscribe(agent_server, endpoint_id, options \\ %{})
      when is_atom(endpoint_id) and is_map(options) do
    identity = agent_identity(agent_server)

    Agent.update(__MODULE__, fn state ->
      normalized = normalize_state(state)

      update_in(normalized, [:subscriptions], fn subscriptions ->
        subscribers = Map.get(subscriptions, endpoint_id, %{})

        Map.put(
          subscriptions,
          endpoint_id,
          Map.put(subscribers, identity, %{agent_server: agent_server, options: options})
        )
      end)
    end)
  end

  @spec unsubscribe(term(), atom()) :: :ok
  def unsubscribe(agent_server, endpoint_id) when is_atom(endpoint_id) do
    identity = agent_identity(agent_server)

    Agent.update(__MODULE__, fn state ->
      normalized = normalize_state(state)

      subscribers =
        normalized
        |> get_in([:subscriptions, endpoint_id])
        |> Kernel.||(%{})
        |> Map.delete(identity)

      subscriptions =
        if map_size(subscribers) == 0 do
          Map.delete(normalized.subscriptions, endpoint_id)
        else
          Map.put(normalized.subscriptions, endpoint_id, subscribers)
        end

      %{normalized | subscriptions: subscriptions}
    end)
  end

  @spec subscribers_for(atom()) :: [subscription()]
  def subscribers_for(endpoint_id) when is_atom(endpoint_id) do
    Agent.get(__MODULE__, fn state ->
      state
      |> normalize_state()
      |> get_in([:subscriptions, endpoint_id])
      |> Kernel.||(%{})
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

  defp initial_state do
    %{entries: %{}, subscriptions: %{}}
  end

  @spec normalize_state(term()) :: registry_state()
  defp normalize_state(%{entries: entries, subscriptions: subscriptions})
       when is_map(entries) and is_map(subscriptions) do
    %{entries: entries, subscriptions: subscriptions}
  end

  defp normalize_state(%{entries: entries, opted_in: opted_in})
       when is_map(entries) and is_map(opted_in) do
    subscriptions =
      Enum.reduce(opted_in, %{}, fn {identity, %{agent_server: agent_server, options: options}},
                                    acc ->
        update_in(acc[:__all__], fn all ->
          (all || %{})
          |> Map.put(identity, %{agent_server: agent_server, options: options || %{}})
        end)
      end)

    %{entries: entries, subscriptions: Map.delete(subscriptions, :__all__)}
  end

  defp normalize_state(state) when is_map(state) do
    %{entries: state, subscriptions: %{}}
  end

  defp normalize_state(_), do: initial_state()
end
