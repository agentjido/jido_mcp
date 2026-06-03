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

  test "ignores root schema dialect metadata" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "type" => "object",
      "required" => ["url"],
      "additionalProperties" => false,
      "properties" => %{
        "url" => %{"type" => "string", "minLength" => 1},
        "response_format" => %{
          "type" => "string",
          "enum" => ["markdown", "json"],
          "default" => "markdown"
        }
      }
    }

    assert {:ok, compiled} = ToolSchemaValidator.compile(schema)
    assert :ok = ToolSchemaValidator.validate(compiled, %{"url" => "123"})

    assert {:error, %{code: :invalid_length, path: ["url"]}} =
             ToolSchemaValidator.validate(compiled, %{"url" => ""})
  end

  test "keeps nested schema dialect metadata unsupported" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "url" => %{
          "$schema" => "http://json-schema.org/draft-07/schema#",
          "type" => "string"
        }
      }
    }

    assert {:error, %{code: :unsupported_schema, path: ["url"]}} =
             ToolSchemaValidator.compile(schema)
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

  test "supports FastMCP nullable anyOf fields" do
    schema = %{
      "type" => "object",
      "required" => ["dataset_id"],
      "properties" => %{
        "dataset_id" => %{
          "anyOf" => [
            %{"type" => "string", "minLength" => 1},
            %{"type" => "null"}
          ],
          "default" => nil,
          "description" => "Optional dataset id"
        },
        "page" => %{
          "anyOf" => [
            %{"type" => "null"},
            %{"type" => "integer", "minimum" => 1}
          ]
        }
      }
    }

    assert {:ok, compiled} = ToolSchemaValidator.compile(schema)

    assert :ok = ToolSchemaValidator.validate(compiled, %{"dataset_id" => "abc", "page" => 2})
    assert :ok = ToolSchemaValidator.validate(compiled, %{"dataset_id" => nil, "page" => nil})
    assert :ok = ToolSchemaValidator.validate(compiled, %{"dataset_id" => "abc"})

    assert {:error, %{code: :invalid_type, path: ["dataset_id"]}} =
             ToolSchemaValidator.validate(compiled, %{"dataset_id" => 123})

    assert {:error, %{code: :invalid_length, path: ["dataset_id"]}} =
             ToolSchemaValidator.validate(compiled, %{"dataset_id" => ""})
  end

  test "keeps non-nullable anyOf unsupported" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "value" => %{
          "anyOf" => [
            %{"type" => "string"},
            %{"type" => "integer"}
          ]
        }
      }
    }

    assert {:error, %{code: :unsupported_schema}} = ToolSchemaValidator.compile(schema)
  end

  test "rejects nullable anyOf with validation siblings" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "value" => %{
          "anyOf" => [
            %{"type" => "string"},
            %{"type" => "null"}
          ],
          "enum" => ["a", nil]
        }
      }
    }

    assert {:error, %{code: :unsupported_schema}} = ToolSchemaValidator.compile(schema)
  end

  test "rejects malformed nullable anyOf shapes" do
    malformed_any_of_values = [
      [%{"type" => "string"}],
      [%{"type" => "string"}, %{"type" => "null"}, %{"type" => "null"}],
      [%{"type" => "null"}, %{"type" => "null"}],
      [%{"type" => "string"}, %{"type" => "null", "enum" => [nil]}],
      [%{"type" => "string"}, %URI{path: "/"}]
    ]

    for any_of <- malformed_any_of_values do
      schema = %{
        "type" => "object",
        "properties" => %{
          "value" => %{"anyOf" => any_of}
        }
      }

      assert {:error, %{code: :unsupported_schema}} = ToolSchemaValidator.compile(schema)
    end
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
