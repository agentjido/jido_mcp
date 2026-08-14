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
    assert endpoint.backend == :anubis
    assert endpoint.backend_options == []
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
             {:sse,
              [
                finch_name: Jido.MCP.Finch,
                server: [base_url: "http://localhost:3000", sse_path: "/sse"]
              ]}

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
              [
                finch_name: Jido.MCP.Finch,
                base_url: "http://localhost:3000",
                mcp_path: "/mcp",
                enable_sse: true
              ]}
  end

  test "uses the managed Finch pool by default and preserves a caller pool" do
    for transport <- [:sse, :streamable_http] do
      assert {:ok, default_endpoint} =
               Endpoint.new(transport, %{
                 transport: {transport, [base_url: "http://localhost:3000"]},
                 client_info: %{name: "my_app"}
               })

      assert {^transport, default_opts} = default_endpoint.transport
      assert default_opts[:finch_name] == Jido.MCP.Finch

      assert {:ok, caller_endpoint} =
               Endpoint.new(transport, %{
                 transport:
                   {transport, [base_url: "http://localhost:3000", finch_name: MyApp.MCPFinch]},
                 client_info: %{name: "my_app"}
               })

      assert {^transport, caller_opts} = caller_endpoint.transport
      assert caller_opts[:finch_name] == MyApp.MCPFinch
    end
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

  test "accepts the ExMCP backend and BEAM-local transport" do
    assert {:ok, endpoint} =
             Endpoint.new(:local, %{
               backend: "ex_mcp",
               backend_options: [protocol_mode: :modern_only],
               transport: {:beam, [server: self()]},
               client_info: %{name: "my_app"}
             })

    assert endpoint.backend == :ex_mcp
    assert endpoint.backend_options == [protocol_mode: :modern_only]
    assert endpoint.transport == {:beam, [server: self()]}
  end

  test "rejects invalid backend configuration" do
    attrs = %{
      transport: {:stdio, [command: "echo"]},
      client_info: %{name: "my_app"}
    }

    assert {:error, {:invalid_backend, :missing_backend, _message}} =
             Endpoint.new(:bad_backend, Map.put(attrs, :backend, :missing_backend))

    assert {:error, {:invalid_backend_options, _options, _message}} =
             Endpoint.new(:bad_options, Map.put(attrs, :backend_options, %{}))
  end

  test "keeps a runtime string id without converting it to an atom" do
    assert {:ok, endpoint} =
             Endpoint.new("runtime-47", %{
               transport: {:stdio, [command: "echo"]},
               client_info: %{name: "my_app"}
             })

    assert endpoint.id == "runtime-47"
  end

  test "rejects unsafe or oversized string endpoint ids" do
    attrs = %{
      transport: {:stdio, [command: "echo"]},
      client_info: %{name: "my_app"}
    }

    for id <- ["bad\0id", "line\nbreak", String.duplicate("a", 256), <<255>>] do
      assert {:error, {:invalid_endpoint_id, ^id}} = Endpoint.new(id, attrs)
    end
  end
end
