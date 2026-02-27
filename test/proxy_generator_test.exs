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

    assert %{code: :invalid_key_type} = message
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
