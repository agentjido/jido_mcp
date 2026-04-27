defmodule Jido.MCP.Transport.STDIOBufferTest do
  use ExUnit.Case, async: true

  alias Jido.MCP.Transport.STDIOBuffer

  test "buffers partial JSON-RPC lines until newline arrives" do
    response = ~s({"jsonrpc":"2.0","id":"1","result":{"ok":true}})

    assert {[], buffer} = STDIOBuffer.push("", String.slice(response, 0, 20))
    assert {messages, ""} = STDIOBuffer.push(buffer, String.slice(response, 20..-1//1) <> "\n")

    assert [%{"id" => "1", "result" => %{"ok" => true}}] = Enum.map(messages, &Jason.decode!/1)
  end

  test "splits multiple complete messages into separate client casts" do
    data =
      [
        ~s({"jsonrpc":"2.0","id":"1","result":{"a":1}}),
        ~s({"jsonrpc":"2.0","id":"2","result":{"b":2}})
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    assert {messages, ""} = STDIOBuffer.push("", data)

    assert [
             %{"id" => "1", "result" => %{"a" => 1}},
             %{"id" => "2", "result" => %{"b" => 2}}
           ] = Enum.map(messages, &Jason.decode!/1)
  end

  test "expands JSON-RPC batches into separate messages" do
    batch =
      Jason.encode!([
        %{"jsonrpc" => "2.0", "id" => "1", "result" => %{"a" => 1}},
        %{"jsonrpc" => "2.0", "id" => "2", "result" => %{"b" => 2}}
      ])

    assert {messages, ""} = STDIOBuffer.push("", batch <> "\n")

    assert [
             %{"id" => "1", "result" => %{"a" => 1}},
             %{"id" => "2", "result" => %{"b" => 2}}
           ] = Enum.map(messages, &Jason.decode!/1)
  end

  test "accepts complete JSON-RPC messages without trailing newline" do
    response = ~s({"jsonrpc":"2.0","id":"1","result":{"ok":true}})

    assert {messages, ""} = STDIOBuffer.push("", response)
    assert [%{"id" => "1", "result" => %{"ok" => true}}] = Enum.map(messages, &Jason.decode!/1)
  end

  test "keeps incomplete trailing JSON buffered" do
    assert {[], buffer} = STDIOBuffer.push("", ~s({"jsonrpc":"2.0","id":"1"))
    assert buffer == ~s({"jsonrpc":"2.0","id":"1")
  end

  test "ignores non-json stdout noise" do
    data = """
    server started
    {"jsonrpc":"2.0","id":"1","result":{"ok":true}}
    not json
    """

    assert {messages, ""} = STDIOBuffer.push("", data)
    assert [%{"id" => "1", "result" => %{"ok" => true}}] = Enum.map(messages, &Jason.decode!/1)
  end

  test "drops unterminated non-json stdout noise" do
    assert {[], ""} = STDIOBuffer.push("", "server started")
  end

  test "ignores json stdout that is not json-rpc" do
    assert {[], ""} = STDIOBuffer.push("", ~s({"level":"info","message":"ready"}) <> "\n")
  end

  test "filters non-json-rpc entries from batches" do
    batch =
      Jason.encode!([
        %{"level" => "info", "message" => "ready"},
        %{"jsonrpc" => "2.0", "id" => "1", "result" => %{"ok" => true}}
      ])

    assert {messages, ""} = STDIOBuffer.push("", batch <> "\n")
    assert [%{"id" => "1", "result" => %{"ok" => true}}] = Enum.map(messages, &Jason.decode!/1)
  end
end
