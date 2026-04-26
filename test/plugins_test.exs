defmodule Jido.MCP.PluginsTest do
  use ExUnit.Case, async: false

  alias Jido.MCP.JidoAI.Plugins.MCPAI
  alias Jido.MCP.Plugins.MCP
  alias Jido.MCP.{ClientPool, Config}

  setup do
    original = Application.get_env(:jido_mcp, :endpoints)

    Application.put_env(:jido_mcp, :endpoints, %{
      github: %{
        transport: {:stdio, [command: "cat", args: []]},
        client_info: %{name: "test"}
      },
      filesystem: %{
        transport: {:stdio, [command: "cat", args: []]},
        client_info: %{name: "test"}
      }
    })

    load_pool_from_config()

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:jido_mcp, :endpoints)
      else
        Application.put_env(:jido_mcp, :endpoints, original)
      end

      load_pool_from_config()
    end)

    :ok
  end

  test "mount normalizes MCP plugin endpoints" do
    assert {:ok, state} =
             MCP.mount(nil, %{
               default_endpoint: "github",
               allowed_endpoints: ["github", :filesystem]
             })

    assert state.default_endpoint == :github
    assert state.allowed_endpoints == [:github, :filesystem]
  end

  test "mount rejects invalid MCP plugin endpoint configuration" do
    assert {:error, :unknown_endpoint} =
             MCP.mount(nil, %{default_endpoint: "missing"})

    assert {:error, {:invalid_allowed_endpoints, :unknown_endpoint}} =
             MCP.mount(nil, %{allowed_endpoints: ["missing"]})

    assert {:error, {:invalid_allowed_endpoints, :invalid_type}} =
             MCP.mount(nil, %{allowed_endpoints: :github})
  end

  test "MCP plugin exposes expected routes and passthrough behavior" do
    routes = MCP.signal_routes(%{})

    assert {"mcp.tools.list", Jido.MCP.Actions.ListTools} in routes
    assert {"mcp.prompts.get", Jido.MCP.Actions.GetPrompt} in routes
    assert {"mcp.endpoint.register", Jido.MCP.Actions.RegisterEndpoint} in routes
    assert {"mcp.endpoint.unregister", Jido.MCP.Actions.UnregisterEndpoint} in routes
    assert {"mcp.endpoint.default.set", Jido.MCP.Actions.SetDefaultEndpoint} in routes

    assert {:ok, :continue} = MCP.handle_signal(%{}, %{})
    assert %{ok: true} == MCP.transform_result(nil, %{ok: true}, %{})
  end

  test "MCPAI plugin mount and routes" do
    assert {:ok, %{enabled: true}} = MCPAI.mount(nil, %{})

    routes = MCPAI.signal_routes(%{})
    assert {"mcp.ai.sync_tools", Jido.MCP.JidoAI.Actions.SyncToolsToAgent} in routes
    assert {"mcp.ai.unsync_tools", Jido.MCP.JidoAI.Actions.UnsyncToolsFromAgent} in routes

    assert {:ok, :continue} = MCPAI.handle_signal(%{}, %{})
    assert %{ok: true} == MCPAI.transform_result(nil, %{ok: true}, %{})
  end

  defp load_pool_from_config do
    :sys.replace_state(ClientPool, fn state ->
      %{state | endpoints: Config.endpoints(), refs: %{}}
    end)
  end
end
