defmodule Jido.MCP.ResponseTest do
  use ExUnit.Case, async: true

  alias Anubis.MCP.Response, as: MCPResponse
  alias Jido.MCP.Response

  test "normalizes successful response" do
    raw = MCPResponse.from_json_rpc(%{"id" => "1", "result" => %{"tools" => []}})

    assert {:ok, result} = Response.normalize(:demo, "tools/list", {:ok, raw})
    assert result.status == :ok
    assert result.endpoint == :demo
    assert result.method == "tools/list"
    assert result.data == %{"tools" => []}
  end

  test "normalizes tool-level error response" do
    raw =
      MCPResponse.from_json_rpc(%{
        "id" => "1",
        "result" => %{"isError" => true, "message" => "boom"}
      })

    assert {:error, error} = Response.normalize(:demo, "tools/call", {:ok, raw})
    assert error.type == :tool_error
    assert error.message == "boom"
  end

  test "normalizes transport error" do
    reason = %{reason: :timeout, message: "Request timed out"}

    assert {:error, error} = Response.normalize(:demo, "tools/list", {:error, reason})
    assert error.type == :transport
    assert error.endpoint == :demo
  end
end
