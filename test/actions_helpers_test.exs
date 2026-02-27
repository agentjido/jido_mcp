defmodule Jido.MCP.Actions.HelpersTest do
  use ExUnit.Case, async: false

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

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:jido_mcp, :endpoints)
      else
        Application.put_env(:jido_mcp, :endpoints, previous)
      end
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
end
