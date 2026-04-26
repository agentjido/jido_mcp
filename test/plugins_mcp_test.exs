defmodule Jido.MCP.Plugins.MCPTest do
  use ExUnit.Case, async: false

  alias Jido.MCP.{ClientPool, Config}
  alias Jido.MCP.Plugins.MCP

  setup do
    previous = Application.get_env(:jido_mcp, :endpoints)

    Application.put_env(:jido_mcp, :endpoints, %{
      github: %{
        transport: {:streamable_http, [base_url: "http://localhost:3000/mcp"]},
        client_info: %{name: "my_app"}
      },
      filesystem: %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      }
    })

    load_pool_from_config()

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

  test "mount defaults to deny-all when allowlist is omitted" do
    assert {:ok, state} = MCP.mount(nil, %{})
    assert state.allowed_endpoints == []
    assert state.default_endpoint == nil
  end

  test "mount resolves configured allowlist and default endpoint" do
    assert {:ok, state} =
             MCP.mount(nil, %{allowed_endpoints: ["github"], default_endpoint: "github"})

    assert state.allowed_endpoints == [:github]
    assert state.default_endpoint == :github
  end

  test "mount accepts :all allowlist" do
    assert {:ok, state} =
             MCP.mount(nil, %{allowed_endpoints: :all, default_endpoint: "github"})

    assert state.allowed_endpoints == :all
    assert state.default_endpoint == :github
  end

  test "mount raises when default endpoint is not allowlisted" do
    assert_raise ArgumentError, ~r/default_endpoint/, fn ->
      MCP.mount(nil, %{default_endpoint: :github, allowed_endpoints: []})
    end
  end

  test "mount resolves runtime-registered endpoints" do
    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:runtime, %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      })

    assert {:ok, ^endpoint} = ClientPool.register_endpoint(endpoint)

    assert {:ok, state} =
             MCP.mount(nil, %{allowed_endpoints: ["runtime"], default_endpoint: "runtime"})

    assert state.allowed_endpoints == [:runtime]
    assert state.default_endpoint == :runtime
  end

  test "plugin routes include runtime default endpoint setter" do
    routes = MCP.signal_routes(%{})
    assert {"mcp.endpoint.register", Jido.MCP.Actions.RegisterEndpoint} in routes
    assert {"mcp.endpoint.unregister", Jido.MCP.Actions.UnregisterEndpoint} in routes
    assert {"mcp.endpoint.default.set", Jido.MCP.Actions.SetDefaultEndpoint} in routes
  end

  defp load_pool_from_config do
    :sys.replace_state(ClientPool, fn state ->
      %{state | endpoints: Config.endpoints(), refs: %{}}
    end)
  end
end
