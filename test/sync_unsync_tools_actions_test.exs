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

  defp load_pool_from_config do
    :sys.replace_state(ClientPool, fn state ->
      %{state | endpoints: Config.endpoints(), refs: %{}}
    end)
  end
end
