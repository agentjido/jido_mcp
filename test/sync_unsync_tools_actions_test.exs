defmodule Jido.MCP.JidoAI.Actions.SyncUnsyncToolsActionsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Jido.MCP.JidoAI.Actions.{SyncToolsToAgent, UnsyncToolsFromAgent}
  alias Jido.MCP.JidoAI.ProxyRegistry
  alias Jido.MCP.{ClientPool, Config}

  defmodule Elixir.Jido.AI do
    def register_tool(agent_server, module) do
      send(self(), {:register_tool, agent_server, module})
      {:ok, %{}}
    end

    def unregister_tool(agent_server, tool_name) do
      send(self(), {:unregister_tool, agent_server, tool_name})
      {:ok, %{}}
    end

    def register_tool_direct(agent, module) do
      send(self(), {:register_tool_direct, module})
      {:ok, put_tool(agent, module)}
    end

    def unregister_tool_direct(agent, tool_name) do
      send(self(), {:unregister_tool_direct, tool_name})
      {:ok, remove_tool(agent, tool_name)}
    end

    defp put_tool(agent, module) do
      Jido.Agent.Strategy.State.update(agent, fn state ->
        config = Map.get(state, :config, %{})
        tools = [module | Map.get(config, :tools, [])] |> Enum.uniq()
        Map.put(state, :config, Map.put(config, :tools, tools))
      end)
    end

    defp remove_tool(agent, tool_name) do
      Jido.Agent.Strategy.State.update(agent, fn state ->
        config = Map.get(state, :config, %{})

        tools =
          Enum.reject(Map.get(config, :tools, []), fn module -> module.name() == tool_name end)

        Map.put(state, :config, Map.put(config, :tools, tools))
      end)
    end
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
    assert_received {:register_tool, :agent_a, _module}
  end

  test "sync uses direct registration when an agent is present in action context" do
    Mimic.expect(Elixir.Jido.MCP, :list_tools, fn :github ->
      {:ok,
       %{
         data: %{
           "tools" => [
             %{
               "name" => "search_issues",
               "description" => "Search issues",
               "inputSchema" => %{"type" => "object", "properties" => %{}}
             }
           ]
         }
       }}
    end)

    agent = %Jido.Agent{state: %{}}

    assert {:ok, result, effects} =
             SyncToolsToAgent.run(
               %{endpoint_id: "github", agent_server: :agent_a, replace_existing: true},
               %{agent: agent}
             )

    assert result.registered_count == 1
    assert [%Jido.Agent.StateOp.SetPath{path: [:__strategy__], value: strategy_state}] = effects
    assert [module] = get_in(strategy_state, [:config, :tools])
    assert result.registered_tools == [module.name()]
    assert String.ends_with?(module.name(), "search_issues")
    assert_received {:register_tool_direct, ^module}
    refute_received {:register_tool, :agent_a, ^module}
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
  end

  test "sync propagates discovery errors" do
    Mimic.expect(Elixir.Jido.MCP, :list_tools, fn :github ->
      {:error, {:endpoint_not_ready, :not_ready}}
    end)

    assert {:error, {:endpoint_not_ready, :not_ready}} =
             SyncToolsToAgent.run(%{endpoint_id: :github, agent_server: :agent_a}, %{})
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

  test "runtime endpoint registration does not auto-sync tools" do
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

    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:runtime, %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      })

    assert {:ok, ^endpoint} = Jido.MCP.register_endpoint(endpoint)

    assert ProxyRegistry.get(:agent_a, :runtime) == []
    assert Agent.get(calls, & &1) |> Enum.count(&(&1 == :runtime)) == 0
  end

  test "runtime endpoint unregistration expects explicit unsync orchestration" do
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

    assert length(ProxyRegistry.get(:agent_a, :runtime)) == 1

    assert {:ok, _unsync} =
             UnsyncToolsFromAgent.run(%{endpoint_id: :runtime, agent_server: :agent_a}, %{})

    assert {:ok, %Jido.MCP.Endpoint{id: :runtime}} = Jido.MCP.unregister_endpoint(:runtime)
    assert ProxyRegistry.get(:agent_a, :runtime) == []
  end

  test "unsync uses direct unregistration when an agent is present in action context" do
    tool = %{
      "name" => "search_issues",
      "description" => "Search issues",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }

    Mimic.stub(Elixir.Jido.MCP, :list_tools, fn :github ->
      {:ok, %{data: %{"tools" => [tool]}}}
    end)

    agent = %Jido.Agent{state: %{}}

    assert {:ok, _result, sync_effects} =
             SyncToolsToAgent.run(
               %{endpoint_id: :github, agent_server: :agent_a, replace_existing: true},
               %{agent: agent}
             )

    assert [%Jido.Agent.StateOp.SetPath{value: sync_strategy_state}] = sync_effects
    assert [module] = get_in(sync_strategy_state, [:config, :tools])
    tool_name = module.name()

    agent = apply_strategy_effect(agent, sync_effects)

    assert {:ok, result, effects} =
             UnsyncToolsFromAgent.run(%{endpoint_id: :github, agent_server: :agent_a}, %{
               agent: agent
             })

    assert result.removed_count == 1
    assert result.purged_count == 1
    assert [%Jido.Agent.StateOp.SetPath{path: [:__strategy__], value: strategy_state}] = effects
    assert get_in(strategy_state, [:config, :tools]) == []
    assert_received {:unregister_tool_direct, ^tool_name}
    refute_received {:unregister_tool, :agent_a, ^tool_name}
  end

  defp load_pool_from_config do
    :sys.replace_state(ClientPool, fn state ->
      %{state | endpoints: Config.endpoints(), refs: %{}}
    end)
  end

  defp apply_strategy_effect(agent, [
         %Jido.Agent.StateOp.SetPath{path: [:__strategy__], value: state}
       ]) do
    %{agent | state: Map.put(agent.state, :__strategy__, state)}
  end
end
