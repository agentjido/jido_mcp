defmodule Jido.MCP.SchemaAdapter.JSVTest do
  use ExUnit.Case, async: true

  alias Jido.MCP.SchemaAdapter.JSV

  test "compiles nil as an empty object schema" do
    assert {:ok, compiled} = JSV.compile(nil, [])
    assert {:ok, %{}} = JSV.validate(compiled, %{})
  end

  test "requires MCP tool input schemas to be root objects" do
    assert {:error, %{code: :invalid_schema, message: message, path: []}} =
             JSV.compile(%{"type" => "array", "items" => %{"type" => "string"}}, [])

    assert message =~ "type must be object"
  end

  test "enforces schema depth and property count limits before compiling" do
    deep_schema = %{
      "type" => "object",
      "properties" => %{
        "one" => %{
          "type" => "object",
          "properties" => %{
            "two" => %{"type" => "string"}
          }
        }
      }
    }

    assert {:error, %{code: :schema_too_deep}} = JSV.compile(deep_schema, max_depth: 2)

    wide_schema = %{
      "type" => "object",
      "properties" => %{
        "one" => %{"type" => "string"},
        "two" => %{"type" => "string"},
        "three" => %{"type" => "string"}
      }
    }

    assert {:error, %{code: :schema_too_large}} = JSV.compile(wide_schema, max_properties: 2)
  end

  test "validates rich MCP JSON Schema and returns string-keyed params" do
    schema = %{
      "type" => "object",
      "required" => ["url", "limit"],
      "properties" => %{
        "url" => %{"type" => "string", "format" => "uri"},
        "excludeDomains" => %{
          "type" => "array",
          "items" => %{"type" => "string", "pattern" => "^[a-z0-9.-]+$"}
        },
        "limit" => %{"type" => "integer", "exclusiveMinimum" => 0},
        "jsonOptions" => %{
          "type" => "object",
          "properties" => %{
            "schema" => %{
              "type" => "object",
              "propertyNames" => %{"type" => "string", "minLength" => 1}
            }
          }
        }
      }
    }

    assert {:ok, compiled} = JSV.compile(schema, [])

    assert {:ok,
            %{
              "url" => "https://example.com",
              "limit" => 1,
              "excludeDomains" => ["example.org"]
            }} =
             JSV.validate(compiled, %{
               url: "https://example.com",
               limit: 1,
               excludeDomains: ["example.org"]
             })

    assert {:error, %{code: :invalid_arguments, path: ["limit"]}} =
             JSV.validate(compiled, %{"url" => "https://example.com", "limit" => 0})
  end
end
