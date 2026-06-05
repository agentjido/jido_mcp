defmodule Jido.MCP.JidoAI.SchemaAdapter.JSVTest do
  use ExUnit.Case, async: true

  alias Jido.MCP.JidoAI.SchemaAdapter.JSV

  test "does not run runtime schema casts that can create atoms" do
    value = "jido_mcp_runtime_atom_#{System.unique_integer([:positive])}"

    schema = %{
      "type" => "object",
      "properties" => %{
        "value" => %{
          "type" => "string",
          "jsv-cast" => [["Elixir.JSV.Cast", "string_to_atom"]]
        }
      }
    }

    assert_raise ArgumentError, fn -> String.to_existing_atom(value) end

    assert {:ok, root} = JSV.compile(schema, [])
    assert :ok = JSV.validate(root, %{"value" => value})

    assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
  end

  test "rejects schemas deeper than max_depth before JSV build" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "outer" => %{
          "type" => "object",
          "properties" => %{
            "inner" => %{"type" => "string"}
          }
        }
      }
    }

    assert {:error,
            %{code: :schema_too_deep, path: ["properties", "outer", "properties", "inner"]}} =
             JSV.compile(schema, max_depth: 2)
  end

  test "rejects schemas with more than max_properties before JSV build" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "one" => %{"type" => "string"},
        "two" => %{"type" => "string"},
        "three" => %{"type" => "string"}
      }
    }

    assert {:error, %{code: :schema_too_large, path: []}} =
             JSV.compile(schema, max_properties: 2)
  end
end
