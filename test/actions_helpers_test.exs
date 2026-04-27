defmodule Jido.MCP.Actions.HelpersTest do
  use ExUnit.Case, async: false

  alias Jido.MCP.{ClientPool, Config}
  alias Jido.MCP.Actions.Helpers

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

  test "resolves endpoint id from params" do
    assert {:ok, :github} = Helpers.resolve_endpoint_id(%{endpoint_id: :github}, %{})
    assert {:ok, :github} = Helpers.resolve_endpoint_id(%{endpoint_id: "github"}, %{})
  end

  test "enforces allowed_endpoints" do
    context = %{allowed_endpoints: [:github]}

    assert {:ok, :github} = Helpers.resolve_endpoint_id(%{endpoint_id: :github}, context)

    assert {:error, :endpoint_not_allowed} =
             Helpers.resolve_endpoint_id(%{endpoint_id: :filesystem}, context)
  end

  test "returns unknown endpoint for unconfigured endpoint names" do
    assert {:error, :unknown_endpoint} =
             Helpers.resolve_endpoint_id(%{endpoint_id: :missing}, %{})

    assert {:error, :unknown_endpoint} =
             Helpers.resolve_endpoint_id(%{endpoint_id: "missing"}, %{})
  end

  test "resolves runtime-registered endpoints" do
    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:runtime, %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      })

    assert {:ok, ^endpoint} = ClientPool.register_endpoint(endpoint)

    assert {:ok, :runtime} = Helpers.resolve_endpoint_id(%{endpoint_id: "runtime"}, %{})
    assert {:ok, :runtime} = Helpers.resolve_endpoint_id(%{endpoint_id: :runtime}, %{})
  end

  defp load_pool_from_config do
    :sys.replace_state(ClientPool, fn state ->
      %{state | endpoints: Config.endpoints(), refs: %{}}
    end)
  end
end
