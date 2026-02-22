defmodule Jido.MCP.Actions.HelpersTest do
  use ExUnit.Case, async: true

  alias Jido.MCP.Actions.Helpers

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
end
