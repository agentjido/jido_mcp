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
    assert endpoint.protocol_version == "2025-06-18"
    assert endpoint.timeouts.request_ms == 30_000
    assert endpoint.capabilities == %{}
  end

  test "supports shell alias, SSE, and streamable HTTP transports" do
    assert {:ok, shell_endpoint} =
             Endpoint.new(:shell, %{
               transport: {:shell, command: "echo", args: ["ok"]},
               client_info: %{name: "my_app"}
             })

    assert shell_endpoint.transport == {:stdio, [command: "echo", args: ["ok"]]}
    assert shell_endpoint.protocol_version == "2025-06-18"

    assert {:ok, sse_endpoint} =
             Endpoint.new(:legacy_sse, %{
               transport: {:sse, base_url: "http://localhost:3000", sse_path: "/sse"},
               client_info: %{name: "my_app"}
             })

    assert sse_endpoint.transport ==
             {:sse, [server: [base_url: "http://localhost:3000", sse_path: "/sse"]]}

    assert sse_endpoint.protocol_version == "2024-11-05"

    assert {:ok, http_endpoint} =
             Endpoint.new(:http, %{
               transport:
                 {:streamable_http,
                  base_url: "http://localhost:3000", mcp_path: "/mcp", enable_sse: true},
               client_info: %{name: "my_app"}
             })

    assert http_endpoint.transport ==
             {:streamable_http,
              [base_url: "http://localhost:3000", mcp_path: "/mcp", enable_sse: true]}
  end

  test "normalizes streamable HTTP URL options for Anubis 1.1" do
    assert {:ok, endpoint} =
             Endpoint.new(:http_url, %{
               transport: {:streamable_http, url: "http://localhost:3000/custom-mcp"},
               client_info: %{name: "my_app"}
             })

    assert {:streamable_http, opts} = endpoint.transport
    assert opts[:base_url] == "http://localhost:3000"
    assert opts[:mcp_path] == "/custom-mcp"

    assert {:ok, query_endpoint} =
             Endpoint.new(:http_url_query, %{
               transport: {:streamable_http, url: "http://localhost:3000/custom-mcp?token=abc"},
               client_info: %{name: "my_app"}
             })

    assert {:streamable_http, opts} = query_endpoint.transport
    assert opts[:base_url] == "http://localhost:3000"
    assert opts[:mcp_path] == "/custom-mcp?token=abc"

    assert {:ok, legacy_endpoint} =
             Endpoint.new(:http_legacy, %{
               transport: {:streamable_http, base_url: "http://localhost:3000/mcp"},
               client_info: %{name: "my_app"}
             })

    assert {:streamable_http, opts} = legacy_endpoint.transport
    assert opts[:base_url] == "http://localhost:3000"
    assert opts[:mcp_path] == "/mcp"

    assert {:ok, base_endpoint} =
             Endpoint.new(:http_base, %{
               transport: {:streamable_http, base_url: "http://localhost:3000/"},
               client_info: %{name: "my_app"}
             })

    assert {:streamable_http, opts} = base_endpoint.transport
    assert opts[:base_url] == "http://localhost:3000/"
    refute Keyword.has_key?(opts, :mcp_path)
  end

  test "rejects invalid transport" do
    assert {:error, {:invalid_transport, _, _}} =
             Endpoint.new(:bad, %{
               transport: {:websocket, url: "ws://localhost:3000/mcp"},
               client_info: %{name: "my_app"}
             })

    assert {:error, {:invalid_transport_options, _, _}} =
             Endpoint.new(:bad, %{
               transport: {:stdio, ["echo"]},
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
