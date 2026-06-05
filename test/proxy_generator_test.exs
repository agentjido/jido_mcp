defmodule Jido.MCP.JidoAI.ProxyGeneratorTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Jido.MCP.SchemaAdapter.StrictSubset
  alias Jido.MCP.JidoAI.ProxyGenerator

  setup :set_mimic_from_context

  defmodule UnexpectedAdapter do
    @behaviour Jido.MCP.SchemaAdapter

    @impl true
    def compile(_schema, _opts), do: :unexpected

    @impl true
    def validate(_compiled_schema, _params), do: :ok
  end

  defmodule ReferenceAdapter do
    @behaviour Jido.MCP.SchemaAdapter

    @impl true
    def compile(_schema, _opts), do: {:ok, make_ref()}

    @impl true
    def validate(compiled_schema, params) when is_reference(compiled_schema) and is_map(params) do
      {:ok, params}
    end
  end

  test "builds proxy module with default JSON Schema validation and normalized params" do
    input_schema = %{
      "type" => "object",
      "required" => ["query"],
      "properties" => %{
        "query" => %{"type" => "string"}
      }
    }

    tools = [
      %{
        "name" => "search_issues",
        "description" => "Search issues",
        "inputSchema" => input_schema
      }
    ]

    assert {:ok, [proxy_module], warnings, skipped} =
             ProxyGenerator.build_modules(:github, tools, prefix: "mcp_")

    assert warnings == %{}
    assert skipped == []
    assert proxy_module.schema() == input_schema
    assert Jido.Action.Schema.schema_type(proxy_module.schema()) == :json_schema

    test_pid = self()

    Mimic.stub(Jido.MCP, :call_tool, fn :github, "search_issues", %{"query" => query} ->
      send(test_pid, {:called_search_issues, query})
      {:ok, %{data: %{"ok" => true}}}
    end)

    assert {:ok, %{"ok" => true}} = Jido.Exec.run(proxy_module, %{"query" => "bug"}, %{})
    assert {:ok, %{"ok" => true}} = Jido.Exec.run(proxy_module, %{query: "atom bug"}, %{})

    assert_received {:called_search_issues, "bug"}
    assert_received {:called_search_issues, "atom bug"}
  end

  test "uses an empty JSON Schema action schema when MCP inputSchema is omitted" do
    tools = [
      %{
        "name" => "ping",
        "description" => "Ping"
      }
    ]

    assert {:ok, [proxy_module], %{}, []} =
             ProxyGenerator.build_modules(:github, tools, prefix: "mcp_")

    assert proxy_module.schema() == %{"type" => "object", "properties" => %{}}
    assert Jido.Action.Schema.schema_type(proxy_module.schema()) == :json_schema
  end

  test "supports strict schema adapter opt-in" do
    tools = [
      %{
        "name" => "search_issues",
        "description" => "Search issues",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{"type" => "string"}
          }
        }
      }
    ]

    assert {:ok, [proxy_module], %{}, []} =
             ProxyGenerator.build_modules(:github, tools,
               prefix: "mcp_strict_",
               schema_adapter: StrictSubset
             )

    assert {:error, %Jido.Action.Error.ExecutionFailureError{message: message}} =
             Jido.Exec.run(proxy_module, %{query: "bug"}, %{})

    assert message == "all object keys must be strings"
  end

  test "rejects invalid schema adapter modules before processing tools" do
    assert {:error, {:invalid_schema_adapter, List}} =
             ProxyGenerator.build_modules(:github, [], schema_adapter: List)
  end

  test "skips tools when schema adapter returns an unexpected compile response" do
    tools = [
      %{
        "name" => "search_issues",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]

    assert {:ok, [], warnings, [skipped]} =
             ProxyGenerator.build_modules(:github, tools, schema_adapter: UnexpectedAdapter)

    assert skipped.tool_name == "search_issues"
    assert [warning] = warnings["search_issues"]
    assert warning =~ "unexpected schema adapter response"
  end

  test "stores compiled schemas that cannot be embedded in generated module AST" do
    tools = [
      %{
        "name" => "search_issues",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]

    assert {:ok, [proxy_module], %{}, []} =
             ProxyGenerator.build_modules(:github, tools, schema_adapter: ReferenceAdapter)

    Mimic.expect(Jido.MCP, :call_tool, fn :github, "search_issues", %{"query" => "bug"} ->
      {:ok, %{data: %{"ok" => true}}}
    end)

    assert {:ok, %{"ok" => true}} = Jido.Exec.run(proxy_module, %{"query" => "bug"}, %{})
  end

  test "uses distinct modules for different local proxy definitions" do
    tools = [
      %{
        "name" => "search_issues",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{}
        }
      }
    ]

    assert {:ok, [default_module], %{}, []} = ProxyGenerator.build_modules(:github, tools)

    tools = [
      %{
        "name" => "search_issues",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{"query" => %{"type" => "string"}}
        }
      }
    ]

    assert {:ok, [prefixed_module], %{}, []} =
             ProxyGenerator.build_modules(:github, tools, prefix: "mcp_")

    refute default_module == prefixed_module
  end

  test "builds proxy modules for FastMCP nullable anyOf fields" do
    tools = [
      %{
        "name" => "get_metrics",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "dataset_id" => %{
              "anyOf" => [
                %{"type" => "string"},
                %{"type" => "null"}
              ],
              "default" => nil
            }
          }
        }
      }
    ]

    assert {:ok, [proxy_module], %{}, []} =
             ProxyGenerator.build_modules(:data_gouv, tools, prefix: "mcp_")

    Mimic.expect(Jido.MCP, :call_tool, fn :data_gouv, "get_metrics", %{"dataset_id" => nil} ->
      {:ok, %{data: %{"ok" => true}}}
    end)

    assert {:ok, %{"ok" => true}} = Jido.Exec.run(proxy_module, %{"dataset_id" => nil}, %{})
  end

  test "builds proxy modules for tools with root schema dialect metadata" do
    tools = [
      %{
        "name" => "tweetsave_get_tweet",
        "inputSchema" => %{
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
      }
    ]

    assert {:ok, [proxy_module], %{}, []} =
             ProxyGenerator.build_modules(:tweetsave, tools, prefix: "mcp_")

    Mimic.expect(Jido.MCP, :call_tool, fn :tweetsave, "tweetsave_get_tweet", %{"url" => "123"} ->
      {:ok, %{data: %{"ok" => true}}}
    end)

    assert {:ok, %{"ok" => true}} = Jido.Exec.run(proxy_module, %{"url" => "123"}, %{})
  end

  test "builds proxy modules for rich MCP JSON Schema constructs by default" do
    input_schema = %{
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

    tools = [
      %{
        "name" => "firecrawl_search",
        "inputSchema" => input_schema
      }
    ]

    assert {:ok, [proxy_module], %{}, []} =
             ProxyGenerator.build_modules(:firecrawl, tools, prefix: "mcp_")

    assert proxy_module.schema() == input_schema

    Mimic.expect(Jido.MCP, :call_tool, fn :firecrawl,
                                          "firecrawl_search",
                                          %{
                                            "url" => "https://example.com",
                                            "limit" => 1,
                                            "excludeDomains" => ["example.org"]
                                          } ->
      {:ok, %{data: %{"ok" => true}}}
    end)

    assert {:ok, %{"ok" => true}} =
             Jido.Exec.run(
               proxy_module,
               %{
                 url: "https://example.com",
                 limit: 1,
                 excludeDomains: ["example.org"]
               },
               %{}
             )
  end

  test "strict schema adapter skips unsupported schema constructs" do
    tools = [
      %{
        "name" => "bad_tool",
        "inputSchema" => %{
          "type" => "object",
          "oneOf" => [%{"type" => "object", "properties" => %{}}]
        }
      }
    ]

    assert {:ok, [], warnings, [skipped]} =
             ProxyGenerator.build_modules(:github, tools, schema_adapter: StrictSubset)

    assert skipped.tool_name == "bad_tool"
    assert is_list(warnings["bad_tool"])
  end
end
