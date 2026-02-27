defmodule Jido.MCP.JidoAI.Actions.SyncUnsyncToolsActionsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Jido.MCP.JidoAI.Actions.{SyncToolsToAgent, UnsyncToolsFromAgent}
  alias Jido.MCP.JidoAI.ProxyRegistry

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

    Agent.update(ProxyRegistry, fn _ -> %{} end)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:jido_mcp, :endpoints)
      else
        Application.put_env(:jido_mcp, :endpoints, previous)
      end
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
end
