defmodule Jido.MCP.JidoAI.ToolSchemaValidatorTest do
  use ExUnit.Case, async: true

  alias Jido.MCP.JidoAI.ToolSchemaValidator

  test "compiles and validates supported object schema subset" do
    schema = %{
      "type" => "object",
      "required" => ["query"],
      "properties" => %{
        "query" => %{"type" => "string", "minLength" => 1},
        "page" => %{"type" => "integer", "minimum" => 1},
        "labels" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "maxItems" => 3
        },
        "options" => %{
          "type" => "object",
          "properties" => %{
            "include_closed" => %{"type" => "boolean"}
          }
        }
      }
    }

    assert {:ok, compiled} = ToolSchemaValidator.compile(schema)
    assert :ok = ToolSchemaValidator.validate(compiled, %{"query" => "bug", "page" => 2})

    assert {:error, %{code: :invalid_key_type}} =
             ToolSchemaValidator.validate(compiled, %{query: "bug"})
  end

  test "rejects unsupported schema constructs fail-closed" do
    schema = %{
      "type" => "object",
      "oneOf" => [
        %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}
      ]
    }

    assert {:error, %{code: :unsupported_schema}} = ToolSchemaValidator.compile(schema)
  end

  test "enforces schema limits for depth and property count" do
    deep_schema = %{
      "type" => "object",
      "properties" => %{
        "level1" => %{
          "type" => "object",
          "properties" => %{
            "level2" => %{
              "type" => "object",
              "properties" => %{
                "level3" => %{"type" => "object", "properties" => %{}}
              }
            }
          }
        }
      }
    }

    assert {:error, %{code: :schema_too_deep}} =
             ToolSchemaValidator.compile(deep_schema, max_depth: 2)

    wide_schema = %{
      "type" => "object",
      "properties" => %{
        "a" => %{"type" => "string"},
        "b" => %{"type" => "string"},
        "c" => %{"type" => "string"}
      }
    }

    assert {:error, %{code: :schema_too_large}} =
             ToolSchemaValidator.compile(wide_schema, max_properties: 2)
  end
end
