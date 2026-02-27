defmodule Jido.MCP.JidoAI.JSONSchemaToZoiTest do
  use ExUnit.Case, async: true

  alias Jido.MCP.JidoAI.JSONSchemaToZoi

  test "returns fallback schema and warning for missing or invalid schemas" do
    assert %{warnings: ["missing schema"]} = JSONSchemaToZoi.convert(nil)
    assert %{warnings: ["schema is not a map"]} = JSONSchemaToZoi.convert("bad")
  end

  test "converts simple object schema to zoi ast" do
    result =
      JSONSchemaToZoi.convert(%{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer", "default" => 30}
        },
        "required" => ["name"]
      })

    assert result.warnings == []
    assert is_tuple(result.schema_ast)
  end

  test "falls back when root schema is not object" do
    result = JSONSchemaToZoi.convert(%{"type" => "string"})
    assert result.warnings == ["root schema is not an object"]
  end
end
