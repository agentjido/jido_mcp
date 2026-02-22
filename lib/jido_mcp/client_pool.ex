defmodule Jido.MCP.ClientPool do
  @moduledoc """
  Shared client pool that manages one Anubis client per configured endpoint.
  """

  use GenServer

  alias Jido.MCP.{Config, Endpoint}

  @registry Jido.MCP.Registry
  @supervisor Jido.MCP.ClientSupervisor

  @type client_ref :: %{
          client: GenServer.name(),
          supervisor: GenServer.name(),
          transport: GenServer.name()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_client(atom()) :: {:ok, Endpoint.t(), client_ref()} | {:error, term()}
  def ensure_client(endpoint_id) when is_atom(endpoint_id) do
    GenServer.call(__MODULE__, {:ensure_client, endpoint_id})
  end

  @spec endpoint_status(atom()) :: {:ok, map()} | {:error, term()}
  def endpoint_status(endpoint_id) when is_atom(endpoint_id) do
    GenServer.call(__MODULE__, {:endpoint_status, endpoint_id})
  end

  @spec refresh(atom()) :: {:ok, Endpoint.t(), client_ref()} | {:error, term()}
  def refresh(endpoint_id) when is_atom(endpoint_id) do
    GenServer.call(__MODULE__, {:refresh, endpoint_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{endpoints: Config.endpoints(), refs: %{}}}
  end

  @impl true
  def handle_call({:ensure_client, endpoint_id}, _from, state) do
    case fetch_endpoint(state, endpoint_id) do
      {:ok, endpoint} ->
        case ensure_started(endpoint_id, endpoint, state) do
          {:ok, ref, state} -> {:reply, {:ok, endpoint, ref}, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:endpoint_status, endpoint_id}, _from, state) do
    case Map.fetch(state.refs, endpoint_id) do
      {:ok, ref} ->
        {:reply,
         {:ok,
          %{
            endpoint_id: endpoint_id,
            client_alive?: process_alive?(ref.client),
            supervisor_alive?: process_alive?(ref.supervisor),
            transport_alive?: process_alive?(ref.transport)
          }}, state}

      :error ->
        {:reply, {:error, :not_started}, state}
    end
  end

  def handle_call({:refresh, endpoint_id}, _from, state) do
    case fetch_endpoint(state, endpoint_id) do
      {:ok, endpoint} ->
        state = maybe_stop_endpoint(endpoint_id, state)

        case ensure_started(endpoint_id, endpoint, state) do
          {:ok, ref, state} -> {:reply, {:ok, endpoint, ref}, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp fetch_endpoint(state, endpoint_id) do
    case Map.fetch(state.endpoints, endpoint_id) do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> {:error, :unknown_endpoint}
    end
  end

  defp ensure_started(endpoint_id, endpoint, state) do
    case Map.fetch(state.refs, endpoint_id) do
      {:ok, ref} ->
        if process_alive?(ref.client) and process_alive?(ref.supervisor) do
          {:ok, ref, state}
        else
          start_endpoint(endpoint_id, endpoint, state)
        end

      :error ->
        start_endpoint(endpoint_id, endpoint, state)
    end
  end

  defp start_endpoint(endpoint_id, endpoint, state) do
    ref = names_for(endpoint_id)

    child_spec = %{
      id: {:mcp_client, endpoint_id},
      start:
        {Anubis.Client.Supervisor, :start_link,
         [
           Jido.MCP.AnubisClient,
           [
             name: ref.supervisor,
             client_name: ref.client,
             transport_name: ref.transport,
             transport: endpoint.transport,
             client_info: endpoint.client_info,
             capabilities: endpoint.capabilities,
             protocol_version: endpoint.protocol_version
           ]
         ]},
      type: :supervisor,
      restart: :transient,
      shutdown: 10_000
    }

    case DynamicSupervisor.start_child(@supervisor, child_spec) do
      {:ok, _pid} ->
        {:ok, ref, put_in(state, [:refs, endpoint_id], ref)}

      {:error, {:already_started, _pid}} ->
        {:ok, ref, put_in(state, [:refs, endpoint_id], ref)}

      {:error, {:shutdown, {:failed_to_start_child, _child, {:already_started, _pid}}}} ->
        {:ok, ref, put_in(state, [:refs, endpoint_id], ref)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp maybe_stop_endpoint(endpoint_id, state) do
    case Map.fetch(state.refs, endpoint_id) do
      {:ok, ref} ->
        if pid = resolve_name(ref.supervisor) do
          DynamicSupervisor.terminate_child(@supervisor, pid)
        end

        %{state | refs: Map.delete(state.refs, endpoint_id)}

      :error ->
        state
    end
  end

  defp names_for(endpoint_id) do
    %{
      supervisor: {:via, Registry, {@registry, {:supervisor, endpoint_id}}},
      client: {:via, Registry, {@registry, {:client, endpoint_id}}},
      transport: {:via, Registry, {@registry, {:transport, endpoint_id}}}
    }
  end

  defp process_alive?(name) do
    case resolve_name(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp resolve_name(name) when is_tuple(name), do: GenServer.whereis(name)
  defp resolve_name(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_name(name) when is_pid(name), do: name
  defp resolve_name(_), do: nil
end
