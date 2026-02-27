defmodule Jido.MCP.EndpointTest do
  use ExUnit.Case, async: true

  alias Jido.MCP.Endpoint

  test "builds endpoint with defaults" do
    assert {:ok, endpoint} =
             Endpoint.new(:github, %{
               transport: {:streamable_http, base_url: "http://localhost:3000/mcp"},
               client_info: %{name: "my_app", version: "1.0.0"}
             })

    assert endpoint.id == :github
    assert endpoint.protocol_version == "2025-03-26"
    assert endpoint.timeouts.request_ms == 30_000
    assert endpoint.capabilities == %{}
  end

  test "rejects invalid transport" do
    assert {:error, {:invalid_transport, _, _}} =
             Endpoint.new(:bad, %{
               transport: {:websocket, url: "ws://localhost:3000/mcp"},
               client_info: %{name: "my_app"}
             })
  end

  test "rejects invalid client info and timeouts" do
    assert {:error, {:invalid_client_info, _, _}} =
             Endpoint.new(:bad, %{
               transport: {:stdio, [command: "echo"]},
               client_info: %{}
             })

    assert {:error, {:invalid_timeouts, _, _}} =
             Endpoint.new(:bad, %{
               transport: {:stdio, [command: "echo"]},
               client_info: %{name: "my_app"},
               timeouts: %{request_ms: 0}
             })
  end
end
