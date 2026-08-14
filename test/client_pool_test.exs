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
    def handle_call(:get_status, _from, status) when is_map(status) do
      {:reply, {:ok, %{connection_status: :ready}}, status}
    end

    def handle_call(:get_status, _from, nil) do
      Process.sleep(100)
      {:reply, :ok, nil}
    end
  end

  defmodule LocalHandler do
    use ExMCP.Server.Handler
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
    assert {:error, :unknown_endpoint} = ClientPool.fetch_endpoint(:missing)
    assert {:error, :unknown_endpoint} = ClientPool.resolve_endpoint_id(:missing)
    assert {:error, :unknown_endpoint} = ClientPool.resolve_endpoint_id("missing")
  end

  test "returns not_started status before endpoint client is initialized" do
    assert {:error, :not_started} = ClientPool.endpoint_status(:github)
  end

  test "lists and resolves endpoints from pool state" do
    assert [:github] = ClientPool.endpoint_ids()
    assert %{github: %Endpoint{id: :github}} = ClientPool.endpoints()
    assert {:ok, %Endpoint{id: :github}} = ClientPool.fetch_endpoint(:github)
    assert {:ok, %Endpoint{id: :github}} = ClientPool.fetch_endpoint("github")
    assert {:ok, :github} = ClientPool.resolve_endpoint_id(:github)
    assert {:ok, :github} = ClientPool.resolve_endpoint_id("github")
    assert {:error, :endpoint_required} = ClientPool.resolve_endpoint_id(nil)
    assert {:error, :invalid_endpoint_id} = ClientPool.resolve_endpoint_id("")
  end

  test "register_endpoint adds a runtime endpoint without starting a client" do
    {:ok, endpoint} =
      Endpoint.new(:runtime, %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      })

    assert {:ok, ^endpoint} = ClientPool.register_endpoint(endpoint)
    assert {:ok, ^endpoint} = ClientPool.fetch_endpoint(:runtime)
    assert [:github, :runtime] = ClientPool.endpoint_ids()
    assert {:ok, :runtime} = ClientPool.resolve_endpoint_id("runtime")
    assert {:error, :not_started} = ClientPool.endpoint_status(:runtime)
  end

  test "register_endpoint keeps an untrusted runtime id as a string" do
    {:ok, endpoint} =
      Endpoint.new("runtime-47", %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      })

    assert {:ok, ^endpoint} = ClientPool.register_endpoint(endpoint)
    assert {:ok, ^endpoint} = ClientPool.fetch_endpoint("runtime-47")
    assert {:ok, "runtime-47"} = ClientPool.resolve_endpoint_id("runtime-47")
    assert [:github, "runtime-47"] = ClientPool.endpoint_ids()
  end

  test "register_endpoint rejects duplicate endpoint ids" do
    {:ok, duplicate} =
      Endpoint.new(:github, %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      })

    assert {:error, {:endpoint_already_registered, :github}} =
             ClientPool.register_endpoint(duplicate)

    assert {:ok, string_duplicate} =
             Endpoint.new("github", %{
               transport: {:stdio, [command: "echo"]},
               client_info: %{name: "my_app"}
             })

    assert {:error, {:endpoint_already_registered, "github"}} =
             ClientPool.register_endpoint(string_duplicate)
  end

  test "register_endpoint validates endpoint structs" do
    invalid = %Endpoint{
      id: :invalid,
      transport: {:websocket, [url: "ws://localhost:3000/mcp"]},
      client_info: %{"name" => "my_app", "version" => "1.0.0"},
      protocol_version: "2025-03-26",
      capabilities: %{},
      timeouts: %{request_ms: 30_000}
    }

    assert {:error, {:invalid_endpoint, {:invalid_transport, _, _}}} =
             ClientPool.register_endpoint(invalid)

    assert {:error, {:invalid_endpoint, {:invalid_endpoint, _, _}}} =
             ClientPool.register_endpoint(%{id: :invalid})
  end

  test "unregister_endpoint removes endpoint and returns removed definition" do
    assert {:ok, %Endpoint{id: :github}} = ClientPool.unregister_endpoint("github")
    assert {:error, :unknown_endpoint} = ClientPool.fetch_endpoint(:github)
    assert {:error, :unknown_endpoint} = ClientPool.unregister_endpoint(:github)
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

  test "restarts tracked endpoints when transport ref is stale" do
    server =
      start_supervised!({ExMCP.Server.HandlerServer, handler: LocalHandler, transport: :beam})

    {:ok, endpoint} =
      Endpoint.new(:github, %{
        transport: {:beam, [server: server]},
        client_info: %{name: "my_app"}
      })

    client = start_supervised!({ReadyClient, %{}})

    {:ok, supervisor} =
      DynamicSupervisor.start_child(
        Jido.MCP.ClientSupervisor,
        {Agent, fn -> nil end}
      )

    supervisor_monitor = Process.monitor(supervisor)
    stale_ref = %{client: client, supervisor: supervisor, transport: :missing_mcp_transport}

    :sys.replace_state(ClientPool, fn state ->
      %{
        state
        | endpoints: %{github: endpoint},
          refs: %{github: stale_ref}
      }
    end)

    assert {:ok, ^endpoint, ref} = ClientPool.ensure_client(:github)
    refute ref == stale_ref
    refute ref.transport == :missing_mcp_transport
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^supervisor, _reason}, 1_000

    on_exit(fn ->
      if Process.alive?(ref.supervisor) do
        DynamicSupervisor.terminate_child(Jido.MCP.ClientSupervisor, ref.supervisor)
      end
    end)
  end

  test "await_ready accepts a ready ExMCP client" do
    client = start_supervised!({ReadyClient, %{}})

    assert :ok = ClientPool.await_ready(%{client: client}, 250)
  end

  test "await_ready returns client_not_ready when capabilities never arrive" do
    client = start_supervised!({ReadyClient, nil})

    assert {:error, :client_not_ready} = ClientPool.await_ready(%{client: client}, 30)
  end

  test "await_ready returns client_not_started when the client ref is stale" do
    assert {:error, :client_not_started} =
             ClientPool.await_ready(%{client: :missing_mcp_client}, 30)
  end
end
