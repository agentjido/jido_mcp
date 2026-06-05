defmodule Jido.MCP.JidoAI.ProxyGeneratorTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Jido.MCP.JidoAI.ProxyGenerator

  setup :set_mimic_from_context

  test "builds proxy module with strict runtime validation" do
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

    assert {:ok, [proxy_module], warnings, skipped} =
             ProxyGenerator.build_modules(:github, tools, prefix: "mcp_")

    assert warnings == %{}
    assert skipped == []

    Mimic.expect(Jido.MCP, :call_tool, fn :github, "search_issues", %{"query" => "bug"} ->
      {:ok, %{data: %{"ok" => true}}}
    end)

    assert {:ok, %{"ok" => true}} = Jido.Exec.run(proxy_module, %{"query" => "bug"}, %{})

    assert {:error, %Jido.Action.Error.ExecutionFailureError{message: message}} =
             Jido.Exec.run(proxy_module, %{query: "bug"}, %{})

    assert message == "all object keys must be strings"
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

  test "skips tools with unsupported schema constructs" do
    tools = [
      %{
        "name" => "bad_tool",
        "inputSchema" => %{
          "type" => "object",
          "oneOf" => [%{"type" => "object", "properties" => %{}}]
        }
      }
    ]

    assert {:ok, [], warnings, [skipped]} = ProxyGenerator.build_modules(:github, tools)
    assert skipped.tool_name == "bad_tool"
    assert is_list(warnings["bad_tool"])
  end
end
