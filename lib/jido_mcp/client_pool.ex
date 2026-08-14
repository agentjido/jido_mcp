defmodule Jido.MCP.ClientPool do
  @moduledoc """
  Shared client pool that manages one backend client per configured endpoint.
  """

  use GenServer

  alias Jido.MCP.{Backend, Config, Endpoint, EndpointID}

  @registry Jido.MCP.Registry
  @supervisor Jido.MCP.ClientSupervisor

  defguardp is_endpoint_id(endpoint_id) when is_atom(endpoint_id) or is_binary(endpoint_id)

  @type client_ref :: %{
          backend: module(),
          client: GenServer.name(),
          supervisor: GenServer.name(),
          transport: GenServer.name()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_client(Endpoint.id()) :: {:ok, Endpoint.t(), client_ref()} | {:error, term()}
  def ensure_client(endpoint_id) when is_endpoint_id(endpoint_id) do
    GenServer.call(__MODULE__, {:ensure_client, endpoint_id}, :infinity)
  end

  @spec await_ready(client_ref(), timeout()) :: :ok | {:error, term()}
  def await_ready(%{client: client} = ref, timeout \\ 5_000) do
    case resolve_name(client) do
      pid when is_pid(pid) ->
        backend = Map.get(ref, :backend, Jido.MCP.Backend.Anubis)
        backend.await_ready(ref, timeout)

      _ ->
        {:error, :client_not_started}
    end
  end

  @spec register_endpoint(Endpoint.t()) ::
          {:ok, Endpoint.t()}
          | {:error, {:endpoint_already_registered, Endpoint.id()} | {:invalid_endpoint, term()}}
  def register_endpoint(endpoint) do
    with {:ok, endpoint} <- validate_endpoint(endpoint) do
      GenServer.call(__MODULE__, {:register_endpoint, endpoint})
    end
  end

  @spec unregister_endpoint(Endpoint.id()) :: {:ok, Endpoint.t()} | {:error, :unknown_endpoint}
  def unregister_endpoint(endpoint_id) when is_endpoint_id(endpoint_id) do
    GenServer.call(__MODULE__, {:unregister_endpoint, endpoint_id}, :infinity)
  end

  @spec fetch_endpoint(Endpoint.id()) :: {:ok, Endpoint.t()} | {:error, :unknown_endpoint}
  def fetch_endpoint(endpoint_id) when is_endpoint_id(endpoint_id) do
    GenServer.call(__MODULE__, {:fetch_endpoint, endpoint_id})
  end

  @spec endpoints() :: Config.endpoints()
  def endpoints do
    GenServer.call(__MODULE__, :endpoints)
  end

  @spec endpoint_ids() :: [Endpoint.id()]
  def endpoint_ids do
    GenServer.call(__MODULE__, :endpoint_ids)
  end

  @spec resolve_endpoint_id(term()) ::
          {:ok, Endpoint.id()}
          | {:error, :endpoint_required | :invalid_endpoint_id | :unknown_endpoint}
  def resolve_endpoint_id(endpoint_id) do
    GenServer.call(__MODULE__, {:resolve_endpoint_id, endpoint_id})
  end

  @spec endpoint_status(Endpoint.id()) :: {:ok, map()} | {:error, term()}
  def endpoint_status(endpoint_id) when is_endpoint_id(endpoint_id) do
    GenServer.call(__MODULE__, {:endpoint_status, endpoint_id})
  end

  @spec refresh(Endpoint.id()) :: {:ok, Endpoint.t(), client_ref()} | {:error, term()}
  def refresh(endpoint_id) when is_endpoint_id(endpoint_id) do
    GenServer.call(__MODULE__, {:refresh, endpoint_id}, :infinity)
  end

  @impl true
  def init(_opts) do
    {:ok, %{endpoints: Config.endpoints(), refs: %{}}}
  end

  @impl true
  def handle_call({:register_endpoint, endpoint}, _from, state) do
    if Enum.any?(Map.keys(state.endpoints), &EndpointID.equivalent?(&1, endpoint.id)) do
      {:reply, {:error, {:endpoint_already_registered, endpoint.id}}, state}
    else
      state = put_in(state, [:endpoints, endpoint.id], endpoint)
      {:reply, {:ok, endpoint}, state}
    end
  end

  def handle_call({:unregister_endpoint, endpoint_id}, _from, state) do
    case resolve_endpoint(state, endpoint_id) do
      {:ok, resolved_id, endpoint} ->
        state =
          resolved_id
          |> maybe_stop_endpoint(state)
          |> then(fn updated_state ->
            %{updated_state | endpoints: Map.delete(updated_state.endpoints, resolved_id)}
          end)

        {:reply, {:ok, endpoint}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fetch_endpoint, endpoint_id}, _from, state) do
    {:reply, fetch_endpoint(state, endpoint_id), state}
  end

  def handle_call(:endpoints, _from, state) do
    {:reply, state.endpoints, state}
  end

  def handle_call(:endpoint_ids, _from, state) do
    {:reply, state.endpoints |> Map.keys() |> Enum.sort_by(&to_string/1), state}
  end

  def handle_call({:resolve_endpoint_id, endpoint_id}, _from, state) do
    {:reply, EndpointID.resolve(endpoint_id, state.endpoints), state}
  end

  def handle_call({:ensure_client, endpoint_id}, _from, state) do
    case resolve_endpoint(state, endpoint_id) do
      {:ok, resolved_id, endpoint} ->
        case ensure_started(resolved_id, endpoint, state) do
          {:ok, ref, state} -> {:reply, {:ok, endpoint, ref}, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:endpoint_status, endpoint_id}, _from, state) do
    with {:ok, resolved_id, _endpoint} <- resolve_endpoint(state, endpoint_id),
         {:ok, ref} <- Map.fetch(state.refs, resolved_id) do
      {:reply,
       {:ok,
        %{
          endpoint_id: resolved_id,
          backend: Map.get(ref, :backend, Jido.MCP.Backend.Anubis),
          client_alive?: process_alive?(ref.client),
          supervisor_alive?: process_alive?(ref.supervisor),
          transport_alive?: process_alive?(ref.transport)
        }}, state}
    else
      :error ->
        {:reply, {:error, :not_started}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:refresh, endpoint_id}, _from, state) do
    case resolve_endpoint(state, endpoint_id) do
      {:ok, resolved_id, endpoint} ->
        state = maybe_stop_endpoint(resolved_id, state)

        case ensure_started(resolved_id, endpoint, state) do
          {:ok, ref, state} -> {:reply, {:ok, endpoint, ref}, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp fetch_endpoint(state, endpoint_id) do
    case resolve_endpoint(state, endpoint_id) do
      {:ok, _resolved_id, endpoint} -> {:ok, endpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_endpoint(state, endpoint_id) do
    with {:ok, resolved_id} <- EndpointID.resolve(endpoint_id, state.endpoints),
         {:ok, endpoint} <- Map.fetch(state.endpoints, resolved_id) do
      {:ok, resolved_id, endpoint}
    else
      :error -> {:error, :unknown_endpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_endpoint(%Endpoint{id: endpoint_id} = endpoint)
       when is_endpoint_id(endpoint_id) do
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
          state = maybe_stop_endpoint(endpoint_id, state)
          start_endpoint(endpoint_id, endpoint, state)
        end

      :error ->
        start_endpoint(endpoint_id, endpoint, state)
    end
  end

  defp start_endpoint(endpoint_id, endpoint, state) do
    ref = names_for(endpoint_id, endpoint.backend)
    backend = ref.backend

    case backend.child_spec(endpoint, ref) do
      {:ok, child_spec} -> start_endpoint_child(endpoint_id, child_spec, ref, state)
      {:error, reason} -> {:error, backend.sanitize_start_error(reason), state}
    end
  end

  defp start_endpoint_child(endpoint_id, child_spec, ref, state) do
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
        {:error, ref.backend.sanitize_start_error(reason), state}
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

  defp names_for(endpoint_id, backend) do
    backend = Backend.module_for(backend)
    client = {:via, Registry, {@registry, {:client, endpoint_id}}}

    %{
      backend: backend,
      supervisor: {:via, Registry, {@registry, {:supervisor, endpoint_id}}},
      client: client,
      transport: transport_name(backend, endpoint_id, client)
    }
  end

  defp transport_name(Jido.MCP.Backend.ExMCP, _endpoint_id, client), do: client

  defp transport_name(_backend, endpoint_id, _client) do
    {:via, Registry, {@registry, {:transport, endpoint_id}}}
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
