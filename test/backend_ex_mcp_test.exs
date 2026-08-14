defmodule Jido.MCP.Backend.ExMCPTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Jido.MCP.Backend.ExMCP, as: ExMCPBackend
  alias Jido.MCP.Endpoint

  setup :set_mimic_from_context

  test "uses the application backend default when an endpoint does not select one" do
    previous = Application.get_env(:jido_mcp, :default_backend)
    Application.put_env(:jido_mcp, :default_backend, :ex_mcp)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:jido_mcp, :default_backend)
      else
        Application.put_env(:jido_mcp, :default_backend, previous)
      end
    end)

    assert {:ok, endpoint} =
             Endpoint.new(:default_backend, %{
               transport: {:stdio, command: "echo"},
               client_info: %{name: "test"}
             })

    assert endpoint.backend == :ex_mcp
  end

  test "maps the existing stdio endpoint shape to ExMCP" do
    assert {:ok, endpoint} =
             Endpoint.new(:stdio, %{
               backend: :ex_mcp,
               transport:
                 {:stdio,
                  command: "node",
                  args: ["server.js"],
                  cwd: "/tmp",
                  env: %{"TOKEN" => "credential"}},
               client_info: %{name: "test"},
               timeouts: %{request_ms: 1_234}
             })

    assert {:ok, opts} = ExMCPBackend.client_options(endpoint, ref(:stdio_client))
    assert opts[:transport] == :stdio
    assert opts[:command] == ["node", "server.js"]
    assert opts[:cd] == "/tmp"
    assert opts[:env] == [{"TOKEN", "credential"}]
    assert opts[:protocol_mode] == :legacy_only
    assert opts[:request_timeout] == 1_234
    assert opts[:reconnect] == false
    assert opts[:retry_policy] == []
  end

  test "keeps lifecycle and retry controls owned by the endpoint backend" do
    for {option, value} <- [
          retry_policy: [max_attempts: 3],
          reconnect: true,
          timeout: :infinity,
          transport: :http,
          headers: [{"Authorization", "Bearer secret"}]
        ] do
      assert {:ok, endpoint} =
               Endpoint.new(:protected, %{
                 backend: :ex_mcp,
                 backend_options: [{option, value}],
                 transport: {:stdio, command: "echo"},
                 client_info: %{name: "test"}
               })

      assert {:error, {:protected_backend_option, ^option}} =
               ExMCPBackend.client_options(endpoint, ref(:protected_client))
    end
  end

  test "allows an explicit ExMCP protocol mode without changing protected options" do
    assert {:ok, endpoint} =
             Endpoint.new(:modern, %{
               backend: :ex_mcp,
               backend_options: [protocol_mode: :prefer_modern],
               transport: {:stdio, command: "echo"},
               client_info: %{name: "test"}
             })

    assert {:ok, opts} = ExMCPBackend.client_options(endpoint, ref(:modern_client))
    assert opts[:protocol_mode] == :prefer_modern
    assert opts[:reconnect] == false
    assert opts[:retry_policy] == []
  end

  test "maps streamable HTTP options and keeps credential clients separate" do
    assert {:ok, first} =
             Endpoint.new(:first, %{
               backend: :ex_mcp,
               transport:
                 {:streamable_http,
                  base_url: "https://mcp.example/mcp",
                  headers: [{"Authorization", "Bearer first"}],
                  enable_sse: false},
               client_info: %{name: "test"}
             })

    assert {:ok, second} =
             Endpoint.new(:second, %{
               backend: :ex_mcp,
               transport:
                 {:streamable_http,
                  base_url: "https://mcp.example/mcp",
                  headers: [{"Authorization", "Bearer second"}],
                  enable_sse: false},
               client_info: %{name: "test"}
             })

    assert {:ok, first_opts} = ExMCPBackend.client_options(first, ref(:first_client))
    assert {:ok, second_opts} = ExMCPBackend.client_options(second, ref(:second_client))

    assert first_opts[:transport] == :http
    assert first_opts[:url] == "https://mcp.example"
    assert first_opts[:endpoint] == "/mcp"
    assert first_opts[:use_sse] == false
    assert first_opts[:headers] == [{"Authorization", "Bearer first"}]
    assert second_opts[:headers] == [{"Authorization", "Bearer second"}]
    refute first_opts[:name] == second_opts[:name]
  end

  test "generic tool calls disable retries unless the caller attests safety" do
    expect(ExMCP.Client, :call_tool, fn :client, "write", %{"value" => 1}, opts ->
      assert opts[:format] == :map
      assert opts[:retry_policy] == false
      assert opts[:http_stream_retry] == :safe_only
      assert opts[:retry_safe] == false
      {:ok, %{"content" => []}}
    end)

    assert {:ok, %{"content" => []}} =
             ExMCPBackend.call_tool(:client, "write", %{"value" => 1}, timeout: 200)

    expect(ExMCP.Client, :call_tool, fn :client, "write", %{}, opts ->
      assert opts[:retry_safe] == true
      assert opts[:idempotency_key] == "operation-1"
      {:ok, %{"content" => []}}
    end)

    assert {:ok, %{"content" => []}} =
             ExMCPBackend.call_tool(:client, "write", %{},
               retry_safe: true,
               idempotency_key: "operation-1"
             )
  end

  test "resource and prompt operations use map parity responses" do
    expect(ExMCP.Client, :list_resources, fn :client, opts ->
      assert_safe_read_opts(opts)
      {:ok, %{"resources" => []}}
    end)

    expect(ExMCP.Client, :list_resource_templates, fn :client, opts ->
      assert_safe_read_opts(opts)
      {:ok, %{"resourceTemplates" => []}}
    end)

    expect(ExMCP.Client, :read_resource, fn :client, "test://resource", opts ->
      assert_safe_read_opts(opts)
      {:ok, %{"contents" => []}}
    end)

    expect(ExMCP.Client, :list_prompts, fn :client, opts ->
      assert_safe_read_opts(opts)
      {:ok, %{"prompts" => []}}
    end)

    expect(ExMCP.Client, :get_prompt, fn :client, "greet", %{}, opts ->
      assert_safe_read_opts(opts)
      {:ok, %{"messages" => []}}
    end)

    assert {:ok, %{"resources" => []}} = ExMCPBackend.list_resources(:client, [])

    assert {:ok, %{"resourceTemplates" => []}} =
             ExMCPBackend.list_resource_templates(:client, [])

    assert {:ok, %{"contents" => []}} =
             ExMCPBackend.read_resource(:client, "test://resource", [])

    assert {:ok, %{"prompts" => []}} = ExMCPBackend.list_prompts(:client, [])
    assert {:ok, %{"messages" => []}} = ExMCPBackend.get_prompt(:client, "greet", %{}, [])
  end

  test "returns an explicit and sanitized outcome-unknown error" do
    expect(ExMCP.Client, :call_tool, fn :client, "write", %{}, _opts ->
      {:error,
       %ExMCP.Error.TransportError{
         transport: :http,
         reason: :outcome_unknown,
         details: %{
           url: "https://mcp.example/mcp?token=secret",
           headers: [{"Authorization", "Bearer secret"}]
         }
       }}
    end)

    assert {:error, error} = ExMCPBackend.call_tool(:client, "write", %{}, [])
    assert error.reason == :outcome_unknown
    assert error.details == %{delivery: :unknown}
    refute inspect(error) =~ "secret"
    refute inspect(error) =~ "mcp.example"
  end

  test "rejects invalid request timeouts before calling ExMCP" do
    assert {:error, error} = ExMCPBackend.list_tools(:client, timeout: :infinity)
    assert error.reason == :invalid_params
    assert error.details == %{field: :timeout}
  end

  test "sanitizes thrown values and invalid protocol codes" do
    expect(ExMCP.Client, :list_tools, fn :client, _opts ->
      throw({:credential, "Bearer secret"})
    end)

    assert {:error, thrown_error} = ExMCPBackend.list_tools(:client, [])
    assert thrown_error.reason == :request_failed
    refute inspect(thrown_error) =~ "secret"

    expect(ExMCP.Client, :list_tools, fn :client, _opts ->
      {:error, %{"code" => "Bearer secret", "message" => "Bearer secret"}}
    end)

    assert {:error, protocol_error} = ExMCPBackend.list_tools(:client, [])
    assert protocol_error.reason == :request_failed
    refute inspect(protocol_error) =~ "secret"
  end

  test "sanitizes client startup failures" do
    assert ExMCPBackend.sanitize_start_error({:connection_error, %{token: "secret"}}) ==
             :connection_failed

    assert ExMCPBackend.sanitize_start_error({:shutdown, {:token, "secret"}}) ==
             :client_start_failed
  end

  test "sanitizes protocol errors before they reach the public envelope" do
    expect(ExMCP.Client, :list_tools, fn :client, _opts ->
      {:error,
       %ExMCP.Error.ProtocolError{
         code: -32_603,
         message: "Bearer secret",
         data: %{"url" => "https://mcp.example?token=secret"}
       }}
    end)

    assert {:error, error} = ExMCPBackend.list_tools(:client, [])
    assert error.reason == :protocol_error
    assert error.details == %{code: -32_603}
    refute inspect(error) =~ "secret"
    refute inspect(error) =~ "mcp.example"
  end

  test "rejects ExMCP transport options that cannot map without changed behavior" do
    assert {:ok, query_endpoint} =
             Endpoint.new(:query, %{
               backend: :ex_mcp,
               transport: {:streamable_http, url: "https://mcp.example/mcp?token=secret"},
               client_info: %{name: "test"}
             })

    assert {:error, {:unsupported_transport_option, :mcp_path_query}} =
             ExMCPBackend.client_options(query_endpoint, ref(:query_client))

    assert {:ok, sse_endpoint} =
             Endpoint.new(:sse, %{
               backend: :ex_mcp,
               transport: {:sse, base_url: "https://mcp.example", sse_path: "/sse"},
               client_info: %{name: "test"}
             })

    assert {:error, {:unsupported_transport, :sse, :ex_mcp}} =
             ExMCPBackend.client_options(sse_endpoint, ref(:sse_client))
  end

  test "rejects unsafe HTTP URL and header forms" do
    for {id, transport, expected} <- [
          {:userinfo, {:streamable_http, base_url: "https://user:secret@mcp.example"},
           {:invalid_transport_options, :base_url}},
          {:query,
           {:streamable_http, base_url: "https://mcp.example?token=secret", mcp_path: "/mcp"},
           {:invalid_transport_options, :base_url}},
          {:authority_path,
           {:streamable_http, base_url: "https://mcp.example", mcp_path: "//other.example"},
           {:invalid_transport_options, :mcp_path}},
          {:header,
           {:streamable_http,
            base_url: "https://mcp.example", headers: [{"X-Test", "ok\r\nX-Evil: yes"}]},
           {:invalid_transport_options, :headers}},
          {:duplicate_header,
           {:streamable_http,
            base_url: "https://mcp.example",
            headers: [{"Authorization", "first"}, {"authorization", "second"}]},
           {:invalid_transport_options, :headers}}
        ] do
      assert {:ok, endpoint} =
               Endpoint.new(id, %{
                 backend: :ex_mcp,
                 transport: transport,
                 client_info: %{name: "test"}
               })

      assert {:error, ^expected} = ExMCPBackend.client_options(endpoint, ref(id))
    end
  end

  test "rejects invalid stdio command, environment, and timeout values" do
    for {id, transport, expected} <- [
          {:command, {:stdio, command: "echo", args: [1]},
           {:invalid_transport_options, :command}},
          {:environment, {:stdio, command: "echo", env: %{"TOKEN" => %{secret: true}}},
           {:invalid_transport_options, :env}},
          {:cwd, {:stdio, command: "echo", cwd: "bad\0path"}, {:invalid_transport_options, :cwd}},
          {:timeout, {:stdio, command: "echo", handshake_timeout: :infinity},
           {:invalid_transport_options, :handshake_timeout}}
        ] do
      assert {:ok, endpoint} =
               Endpoint.new(id, %{
                 backend: :ex_mcp,
                 transport: transport,
                 client_info: %{name: "test"}
               })

      assert {:error, ^expected} = ExMCPBackend.client_options(endpoint, ref(id))
    end
  end

  defp assert_safe_read_opts(opts) do
    assert opts[:format] == :map
    assert opts[:retry_policy] == false
    assert opts[:http_stream_retry] == :safe_only
  end

  defp ref(client) do
    %{
      backend: ExMCPBackend,
      client: client,
      supervisor: :supervisor,
      transport: client
    }
  end
end
