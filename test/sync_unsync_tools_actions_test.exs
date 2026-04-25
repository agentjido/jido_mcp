defmodule Jido.MCP.JidoAI.Actions.SyncUnsyncToolsActionsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Jido.MCP.JidoAI.Actions.{SyncToolsToAgent, UnsyncToolsFromAgent}
  alias Jido.MCP.JidoAI.ProxyRegistry
  alias Jido.MCP.{ClientPool, Config}

  defmodule Elixir.Jido.AI do
    def register_tool(_agent_server, _module), do: {:ok, %{}}
    def unregister_tool(_agent_server, _tool_name), do: {:ok, %{}}
  end

  setup :set_mimic_from_context

  setup do
    previous = Application.get_env(:jido_mcp, :endpoints)

    Application.put_env(:jido_mcp, :endpoints, %{
      github: %{
        transport: {:streamable_http, [base_url: "http://localhost:3000/mcp"]},
        client_info: %{name: "my_app"}
      }
    })

    load_pool_from_config()
    Agent.update(ProxyRegistry, fn _ -> %{entries: %{}, subscriptions: %{}} end)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:jido_mcp, :endpoints)
      else
        Application.put_env(:jido_mcp, :endpoints, previous)
      end

      load_pool_from_config()
    end)

    :ok
  end

  test "sync registers validated proxy modules for configured endpoint ids" do
    Mimic.expect(Elixir.Jido.MCP, :list_tools, fn :github ->
      {:ok,
       %{
         data: %{
           "tools" => [
             %{
               "name" => "search_issues",
               "description" => "Search issues",
               "inputSchema" => %{
                 "type" => "object",
                 "required" => ["query"],
                 "properties" => %{"query" => %{"type" => "string"}}
               }
             }
           ]
         }
       }}
    end)

    assert {:ok, result} =
             SyncToolsToAgent.run(
               %{endpoint_id: "github", agent_server: :agent_a, replace_existing: true},
               %{}
             )

    assert result.endpoint_id == :github
    assert result.discovered_count == 1
    assert result.registered_count == 1
    assert result.failed_count == 0
    assert length(ProxyRegistry.get(:agent_a, :github)) == 1
  end

  test "sync resolves runtime-registered endpoint ids" do
    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:runtime, %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      })

    assert {:ok, ^endpoint} = ClientPool.register_endpoint(endpoint)

    Mimic.expect(Elixir.Jido.MCP, :list_tools, fn :runtime ->
      {:ok, %{data: %{"tools" => []}}}
    end)

    assert {:ok, result} =
             SyncToolsToAgent.run(
               %{endpoint_id: "runtime", agent_server: :agent_a, replace_existing: true},
               %{}
             )

    assert result.endpoint_id == :runtime
    assert result.discovered_count == 0
    assert result.list_tools_attempts == 1
    refute result.list_tools_retried?
  end

  test "sync retries transient server capability initialization errors" do
    runtime_tool = %{
      "name" => "search_issues",
      "description" => "Search issues",
      "inputSchema" => %{
        "type" => "object",
        "required" => ["query"],
        "properties" => %{"query" => %{"type" => "string"}}
      }
    }

    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Mimic.stub(Elixir.Jido.MCP, :list_tools, fn :github ->
      current = Agent.get_and_update(attempts, fn value -> {value + 1, value + 1} end)

      if current < 3 do
        {:error, %{status: :error, message: "Server capabilities not set"}}
      else
        {:ok, %{data: %{"tools" => [runtime_tool]}}}
      end
    end)

    assert {:ok, result} =
             SyncToolsToAgent.run(%{endpoint_id: :github, agent_server: :agent_a}, %{})

    assert result.list_tools_attempts == 3
    assert result.list_tools_retried?
    assert result.registered_count == 1
  end

  test "unsync resolves runtime-registered endpoint ids" do
    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:runtime, %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      })

    assert {:ok, ^endpoint} = ClientPool.register_endpoint(endpoint)

    assert {:ok, result} =
             UnsyncToolsFromAgent.run(%{endpoint_id: "runtime", agent_server: :agent_a}, %{})

    assert result.endpoint_id == :runtime
    assert result.removed_count == 0
  end

  test "sync fails closed when discovered tools exceed configured cap" do
    tools =
      Enum.map(1..201, fn index ->
        %{
          "name" => "tool_#{index}",
          "inputSchema" => %{"type" => "object", "properties" => %{}}
        }
      end)

    Mimic.expect(Elixir.Jido.MCP, :list_tools, fn :github ->
      {:ok, %{data: %{"tools" => tools}}}
    end)

    assert {:error, {:tool_limit_exceeded, %{max_tools: 200, discovered: 201}}} =
             SyncToolsToAgent.run(%{endpoint_id: :github, agent_server: :agent_a}, %{})
  end

  test "unsync keeps shared proxy modules until last agent removes them" do
    tool = %{
      "name" => "search_issues",
      "description" => "Search issues",
      "inputSchema" => %{
        "type" => "object",
        "required" => ["query"],
        "properties" => %{"query" => %{"type" => "string"}}
      }
    }

    Mimic.stub(Elixir.Jido.MCP, :list_tools, fn :github ->
      {:ok, %{data: %{"tools" => [tool]}}}
    end)

    assert {:ok, _} =
             SyncToolsToAgent.run(
               %{endpoint_id: :github, agent_server: :agent_a, replace_existing: true},
               %{}
             )

    assert {:ok, _} =
             SyncToolsToAgent.run(
               %{endpoint_id: :github, agent_server: :agent_b, replace_existing: true},
               %{}
             )

    assert {:ok, result_a} =
             UnsyncToolsFromAgent.run(%{endpoint_id: :github, agent_server: :agent_a}, %{})

    assert result_a.removed_count == 1
    assert result_a.retained_count == 1
    assert result_a.purged_count == 0

    assert {:ok, result_b} =
             UnsyncToolsFromAgent.run(%{endpoint_id: :github, agent_server: :agent_b}, %{})

    assert result_b.removed_count == 1
    assert result_b.retained_count == 0
    assert result_b.purged_count == 1
  end

  test "runtime endpoint registration syncs tools only for endpoint subscribers" do
    runtime_tool = %{
      "name" => "search_issues",
      "description" => "Search issues",
      "inputSchema" => %{
        "type" => "object",
        "required" => ["query"],
        "properties" => %{"query" => %{"type" => "string"}}
      }
    }

    calls = Agent.start_link(fn -> [] end) |> elem(1)

    Mimic.stub(Elixir.Jido.MCP, :list_tools, fn endpoint_id ->
      Agent.update(calls, fn acc -> [endpoint_id | acc] end)

      case endpoint_id do
        :github -> {:ok, %{data: %{"tools" => []}}}
        :runtime -> {:ok, %{data: %{"tools" => [runtime_tool]}}}
      end
    end)

    ProxyRegistry.subscribe(:agent_a, :runtime, %{})
    ProxyRegistry.subscribe(:agent_b, :github, %{})

    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:runtime, %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      })

    assert {:ok, ^endpoint} = Jido.MCP.register_endpoint(endpoint)

    assert length(ProxyRegistry.get(:agent_a, :runtime)) == 1
    assert ProxyRegistry.get(:agent_b, :runtime) == []

    assert Agent.get(calls, & &1) |> Enum.count(&(&1 == :runtime)) == 1
  end

  test "runtime endpoint unregistration unsyncs only subscribed agents" do
    runtime_tool = %{
      "name" => "search_issues",
      "description" => "Search issues",
      "inputSchema" => %{
        "type" => "object",
        "required" => ["query"],
        "properties" => %{"query" => %{"type" => "string"}}
      }
    }

    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:runtime, %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      })

    assert {:ok, ^endpoint} = ClientPool.register_endpoint(endpoint)

    Mimic.stub(Elixir.Jido.MCP, :list_tools, fn endpoint_id ->
      case endpoint_id do
        :github -> {:ok, %{data: %{"tools" => []}}}
        :runtime -> {:ok, %{data: %{"tools" => [runtime_tool]}}}
      end
    end)

    assert {:ok, _} =
             SyncToolsToAgent.run(
               %{endpoint_id: :runtime, agent_server: :agent_a, replace_existing: true},
               %{}
             )

    ProxyRegistry.subscribe(:agent_b, :github, %{})

    assert length(ProxyRegistry.get(:agent_a, :runtime)) == 1

    assert {:ok, %Jido.MCP.Endpoint{id: :runtime}} = Jido.MCP.unregister_endpoint(:runtime)
    assert ProxyRegistry.get(:agent_a, :runtime) == []
    assert ProxyRegistry.get(:agent_b, :runtime) == []
  end

  defp load_pool_from_config do
    :sys.replace_state(ClientPool, fn state ->
      %{state | endpoints: Config.endpoints(), refs: %{}}
    end)
  end
end
