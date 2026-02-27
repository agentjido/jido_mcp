defmodule Jido.MCP.Plugins.MCPTest do
  use ExUnit.Case, async: false

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

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:jido_mcp, :endpoints)
      else
        Application.put_env(:jido_mcp, :endpoints, previous)
      end
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

  test "mount raises when default endpoint is not allowlisted" do
    assert_raise ArgumentError, ~r/default_endpoint/, fn ->
      MCP.mount(nil, %{default_endpoint: :github, allowed_endpoints: []})
    end
  end
end
