defmodule Jido.MCP.ClientPoolTest do
  use ExUnit.Case, async: false

  alias Jido.MCP.{ClientPool, Endpoint}

  defmodule ReadyClient do
    use GenServer

    def start_link(capabilities) do
      GenServer.start_link(__MODULE__, capabilities)
    end

    @impl true
    def init(capabilities), do: {:ok, capabilities}

    @impl true
    def handle_call(:get_server_capabilities, _from, [nil | rest]) do
      {:reply, nil, rest}
    end

    def handle_call(:get_server_capabilities, _from, [capabilities | rest]) do
      {:reply, capabilities, rest}
    end

    def handle_call(:get_server_capabilities, _from, capabilities) do
      {:reply, capabilities, capabilities}
    end
  end

  setup do
    {:ok, endpoint} =
      Endpoint.new(:github, %{
        transport: {:streamable_http, [base_url: "http://localhost:3000/mcp"]},
        client_info: %{name: "my_app"}
      })

    :sys.replace_state(ClientPool, fn _ ->
      %{
        endpoints: %{github: endpoint},
        refs: %{}
      }
    end)

    :ok
  end

  test "returns unknown endpoint when endpoint id is missing from pool state" do
    assert {:error, :unknown_endpoint} = ClientPool.ensure_client(:missing)
    assert {:error, :unknown_endpoint} = ClientPool.refresh(:missing)
  end

  test "returns not_started status before endpoint client is initialized" do
    assert {:error, :not_started} = ClientPool.endpoint_status(:github)
  end

  test "reports liveness flags for tracked refs" do
    :sys.replace_state(ClientPool, fn state ->
      put_in(state, [:refs, :github], %{
        client: :nonexistent_client_name,
        supervisor: :nonexistent_supervisor_name,
        transport: :nonexistent_transport_name
      })
    end)

    assert {:ok, status} = ClientPool.endpoint_status(:github)
    refute status.client_alive?
    refute status.supervisor_alive?
    refute status.transport_alive?
  end

  test "await_ready waits until server capabilities are available" do
    client = start_supervised!({ReadyClient, [nil, %{"tools" => %{}}]})

    assert :ok = ClientPool.await_ready(%{client: client}, 250)
  end

  test "await_ready returns client_not_ready when capabilities never arrive" do
    client = start_supervised!({ReadyClient, nil})

    assert {:error, :client_not_ready} = ClientPool.await_ready(%{client: client}, 30)
  end
end
