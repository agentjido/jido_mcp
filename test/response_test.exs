defmodule Jido.MCP.ResponseTest do
  use ExUnit.Case, async: true

  alias Jido.MCP.Response

  test "normalizes successful response" do
    raw = %{"tools" => []}

    assert {:ok, result} = Response.normalize(:demo, "tools/list", {:ok, raw})
    assert result.status == :ok
    assert result.endpoint == :demo
    assert result.method == "tools/list"
    assert result.data == %{"tools" => []}
    assert Map.keys(result) |> Enum.sort() == [:data, :endpoint, :method, :raw, :status]
  end

  test "normalizes an ExMCP map without changing envelope keys" do
    raw = %{"resources" => [%{"uri" => "test://resource"}]}

    assert {:ok, result} = Response.normalize(:demo, "resources/list", {:ok, raw})
    assert result.data == raw
    assert result.raw == raw
    assert Map.keys(result) |> Enum.sort() == [:data, :endpoint, :method, :raw, :status]
  end

  test "normalizes tool-level error response" do
    raw = %{"isError" => true, "message" => "boom"}

    assert {:error, error} = Response.normalize(:demo, "tools/call", {:ok, raw})
    assert error.type == :tool_error
    assert error.message == "boom"
    assert error.method == "tools/call"
  end

  test "normalizes an ExMCP tool-level error map" do
    raw = %{"isError" => true, "content" => [%{"type" => "text", "text" => "boom"}]}

    assert {:error, error} = Response.normalize(:demo, "tools/call", {:ok, raw})
    assert error.type == :tool_error
    assert error.details == raw

    assert Map.keys(error) |> Enum.sort() ==
             [:details, :endpoint, :message, :method, :status, :type]
  end

  test "normalizes transport error" do
    reason = %{reason: :timeout, message: "Request timed out"}

    assert {:error, error} = Response.normalize(:demo, "tools/list", {:error, reason})
    assert error.type == :transport
    assert error.endpoint == :demo
    assert error.method == "tools/list"
  end

  test "classifies validation and protocol errors consistently" do
    assert {:error, parse_error} =
             Response.normalize(:demo, "tools/call", {:error, %{reason: :parse_error}})

    assert parse_error.type == :validation

    assert {:error, protocol_error} =
             Response.normalize(:demo, "tools/call", {:error, {:error, :invalid_request}})

    assert protocol_error.type == :protocol
  end

  test "classifies protocol and validation errors" do
    assert {:error, protocol_error} =
             Response.normalize(:demo, "tools/list", {:error, %{reason: :method_not_found}})

    assert protocol_error.type == :protocol

    assert {:error, validation_error} =
             Response.normalize(:demo, "tools/call", {:error, %{reason: :invalid_params}})

    assert validation_error.type == :validation
  end

  test "extracts error messages from different response shapes" do
    assert {:error, error} =
             Response.normalize(:demo, "tools/list", {:error, %{"message" => "msg"}})

    assert error.message == "msg"

    assert {:error, error} =
             Response.normalize(:demo, "tools/list", {:error, %{error: "failure"}})

    assert error.message == "failure"

    assert {:error, error} =
             Response.normalize(:demo, "tools/list", {:error, %{reason: :other}})

    assert error.type == :transport
    assert error.message =~ "reason"
  end

  test "normalizes an invalid client response without exposing its contents" do
    assert {:error, error} =
             Response.normalize(:demo, "tools/list", {:unexpected, "Bearer secret"})

    assert error.message == "The MCP client returned an invalid response"
    assert error.details == :invalid_client_response
    refute inspect(error) =~ "secret"
  end
end
