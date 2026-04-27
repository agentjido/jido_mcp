defmodule Jido.MCP.ClientPool do
  @moduledoc """
  Shared client pool that manages one Anubis client per configured endpoint.
  """

  use GenServer

  alias Jido.MCP.{Config, Endpoint, EndpointID}

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

  @spec await_ready(client_ref(), timeout()) :: :ok | {:error, term()}
  def await_ready(%{client: client}, timeout \\ 5_000) do
    case resolve_name(client) do
      pid when is_pid(pid) ->
        anubis_await_ready(client, timeout)

      _ ->
        {:error, :client_not_started}
    end
  end

  @spec register_endpoint(Endpoint.t()) ::
          {:ok, Endpoint.t()}
          | {:error, {:endpoint_already_registered, atom()} | {:invalid_endpoint, term()}}
  def register_endpoint(endpoint) do
    with {:ok, endpoint} <- validate_endpoint(endpoint) do
      GenServer.call(__MODULE__, {:register_endpoint, endpoint})
    end
  end

  @spec unregister_endpoint(atom()) :: {:ok, Endpoint.t()} | {:error, :unknown_endpoint}
  def unregister_endpoint(endpoint_id) when is_atom(endpoint_id) do
    GenServer.call(__MODULE__, {:unregister_endpoint, endpoint_id})
  end

  @spec fetch_endpoint(atom()) :: {:ok, Endpoint.t()} | {:error, :unknown_endpoint}
  def fetch_endpoint(endpoint_id) when is_atom(endpoint_id) do
    GenServer.call(__MODULE__, {:fetch_endpoint, endpoint_id})
  end

  @spec endpoints() :: Config.endpoints()
  def endpoints do
    GenServer.call(__MODULE__, :endpoints)
  end

  @spec endpoint_ids() :: [atom()]
  def endpoint_ids do
    GenServer.call(__MODULE__, :endpoint_ids)
  end

  @spec resolve_endpoint_id(term()) ::
          {:ok, atom()} | {:error, :endpoint_required | :invalid_endpoint_id | :unknown_endpoint}
  def resolve_endpoint_id(endpoint_id) do
    GenServer.call(__MODULE__, {:resolve_endpoint_id, endpoint_id})
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
  def handle_call({:register_endpoint, endpoint}, _from, state) do
    if Map.has_key?(state.endpoints, endpoint.id) do
      {:reply, {:error, {:endpoint_already_registered, endpoint.id}}, state}
    else
      state = put_in(state, [:endpoints, endpoint.id], endpoint)
      {:reply, {:ok, endpoint}, state}
    end
  end

  def handle_call({:unregister_endpoint, endpoint_id}, _from, state) do
    case fetch_endpoint(state, endpoint_id) do
      {:ok, endpoint} ->
        state =
          endpoint_id
          |> maybe_stop_endpoint(state)
          |> then(fn updated_state ->
            %{updated_state | endpoints: Map.delete(updated_state.endpoints, endpoint_id)}
          end)

        {:reply, {:ok, endpoint}, state}

      {:error, :unknown_endpoint} ->
        {:reply, {:error, :unknown_endpoint}, state}
    end
  end

  def handle_call({:fetch_endpoint, endpoint_id}, _from, state) do
    {:reply, fetch_endpoint(state, endpoint_id), state}
  end

  def handle_call(:endpoints, _from, state) do
    {:reply, state.endpoints, state}
  end

  def handle_call(:endpoint_ids, _from, state) do
    {:reply, state.endpoints |> Map.keys() |> Enum.sort(), state}
  end

  def handle_call({:resolve_endpoint_id, endpoint_id}, _from, state) do
    {:reply, EndpointID.resolve(endpoint_id, state.endpoints), state}
  end

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

  defp validate_endpoint(%Endpoint{id: endpoint_id} = endpoint) when is_atom(endpoint_id) do
    endpoint_id
    |> Endpoint.new(Map.from_struct(endpoint))
    |> case do
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, reason} -> {:error, {:invalid_endpoint, reason}}
    end
  end

  defp validate_endpoint(%Endpoint{id: endpoint_id}) do
    {:error, {:invalid_endpoint, {:invalid_endpoint_id, endpoint_id}}}
  end

  defp validate_endpoint(other) do
    {:error,
     {:invalid_endpoint, {:invalid_endpoint, other, "endpoint must be a %Jido.MCP.Endpoint{}"}}}
  end

  defp ensure_started(endpoint_id, endpoint, state) do
    case Map.fetch(state.refs, endpoint_id) do
      {:ok, ref} ->
        if process_alive?(ref.client) and process_alive?(ref.supervisor) and
             process_alive?(ref.transport) do
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
    child_spec = child_spec(endpoint_id, endpoint, ref)

    case DynamicSupervisor.start_child(@supervisor, child_spec) do
      {:ok, pid} ->
        ref = %{ref | supervisor: pid}
        {:ok, ref, put_in(state, [:refs, endpoint_id], ref)}

      {:error, {:already_started, pid}} ->
        ref = %{ref | supervisor: pid}
        {:ok, ref, put_in(state, [:refs, endpoint_id], ref)}

      {:error, {:shutdown, {:failed_to_start_child, _child, {:already_started, pid}}}} ->
        ref = %{ref | supervisor: pid}
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

  defp child_spec(endpoint_id, %{transport: {:stdio, transport_opts}} = endpoint, ref) do
    client_opts = [
      transport: [layer: Anubis.Transport.STDIO, name: ref.transport],
      client_info: endpoint.client_info,
      capabilities: endpoint.capabilities,
      protocol_version: endpoint.protocol_version,
      name: ref.client
    ]

    children = [
      %{id: Anubis.Client, start: {Anubis.Client, :start_link_server, [client_opts]}},
      {Jido.MCP.Transport.STDIO, transport_opts ++ [name: ref.transport, client: ref.client]}
    ]

    %{
      id: {:mcp_client, endpoint_id},
      start:
        {Supervisor, :start_link, [children, [strategy: :one_for_all, name: ref.supervisor]]},
      type: :supervisor,
      restart: :transient,
      shutdown: 10_000
    }
  end

  defp child_spec(endpoint_id, endpoint, ref) do
    %{
      id: {:mcp_client, endpoint_id},
      start:
        {Anubis.Client.Supervisor, :start_link,
         [
           [
             name: ref.client,
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
  end

  defp anubis_await_ready(client, timeout) do
    Anubis.Client.await_ready(client, timeout: timeout)
  catch
    :exit, {:timeout, _} -> {:error, :client_not_ready}
    :exit, {:noproc, _} -> {:error, :client_not_started}
    :exit, reason -> {:error, reason}
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
