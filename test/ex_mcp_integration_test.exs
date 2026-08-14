defmodule Jido.MCP.ExMCPIntegrationTest.HTTPServer do
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(owner), do: owner

  @impl true
  def call(conn, owner) do
    {:ok, body, conn} = read_body(conn)
    request = Jason.decode!(body)
    method = request["method"]
    authorization = get_req_header(conn, "authorization") |> List.first()
    send(owner, {:mcp_http_request, method, authorization})

    case {method, Map.get(request, "id")} do
      {_notification, nil} ->
        send_resp(conn, 202, "")

      {"initialize", id} ->
        json_response(conn, id, %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "jido-mcp-http-test", "version" => "1.0.0"}
        })

      {"tools/list", id} ->
        json_response(conn, id, %{
          "tools" => [
            %{
              "name" => authorization,
              "description" => "Credential-bound tool",
              "inputSchema" => %{"type" => "object"}
            }
          ]
        })

      {"tools/call", id} ->
        json_response(conn, id, %{
          "content" => [%{"type" => "text", "text" => authorization}]
        })

      {_method, id} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => %{"code" => -32_601, "message" => "Method not found"}
          })
        )
    end
  end

  defp json_response(conn, id, result) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    )
  end
end

defmodule Jido.MCP.ExMCPIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.MCP.{ClientPool, Endpoint}

  @stdio_endpoint :ex_mcp_stdio_integration
  @http_endpoint_a :ex_mcp_http_integration_a
  @http_endpoint_b :ex_mcp_http_integration_b
  @http_ref Jido.MCP.ExMCPIntegrationTest.HTTPListener

  setup do
    Enum.each([@stdio_endpoint, @http_endpoint_a, @http_endpoint_b], &remove_endpoint/1)

    on_exit(fn ->
      Enum.each([@stdio_endpoint, @http_endpoint_a, @http_endpoint_b], &remove_endpoint/1)
    end)

    :ok
  end

  test "stdio has tool, resource, and prompt parity and cleans up cancellation and timeout" do
    log_path =
      Path.join(
        System.tmp_dir!(),
        "jido_mcp_ex_mcp_stdio_#{System.unique_integer([:positive])}.log"
      )

    File.write!(log_path, "")
    on_exit(fn -> File.rm(log_path) end)

    {:ok, endpoint} = stdio_endpoint(log_path)
    assert {:ok, ^endpoint} = Jido.MCP.register_endpoint(endpoint)

    assert {:ok, %{data: %{"tools" => tools}, raw: %{"tools" => raw_tools}}} =
             Jido.MCP.list_tools(@stdio_endpoint)

    assert raw_tools == tools
    assert Enum.any?(tools, &(&1["name"] == "echo"))

    assert {:ok, %{data: %{"content" => [%{"text" => "hello"}]}}} =
             Jido.MCP.call_tool(@stdio_endpoint, "echo", %{"text" => "hello"})

    assert {:ok, %{data: %{"resources" => [%{"uri" => "test://resource"}]}}} =
             Jido.MCP.list_resources(@stdio_endpoint)

    assert {:ok, %{data: %{"resourceTemplates" => [_template]}}} =
             Jido.MCP.list_resource_templates(@stdio_endpoint)

    assert {:ok, %{data: %{"contents" => [%{"text" => "resource"}]}}} =
             Jido.MCP.read_resource(@stdio_endpoint, "test://resource")

    assert {:ok, %{data: %{"prompts" => [%{"name" => "greet"}]}}} =
             Jido.MCP.list_prompts(@stdio_endpoint)

    assert {:ok, %{data: %{"messages" => [%{"role" => "user"}]}}} =
             Jido.MCP.get_prompt(@stdio_endpoint, "greet")

    assert {:ok, ^endpoint, ref} = ClientPool.ensure_client(@stdio_endpoint)
    client_pid = GenServer.whereis(ref.client)
    client_state = :sys.get_state(client_pid)
    os_pid = client_state.transport_state.os_pid

    cancellation =
      Task.async(fn ->
        Jido.MCP.call_tool(
          @stdio_endpoint,
          "slow",
          %{"delay_ms" => 200},
          timeout: 2_000
        )
      end)

    assert_eventually(fn -> ExMCP.Client.get_pending_requests(ref.client) != [] end)
    [request_id | _rest] = ExMCP.Client.get_pending_requests(ref.client)
    assert :ok = ExMCP.Client.send_cancelled(ref.client, request_id, "test cancellation")
    assert {:error, %{message: "The MCP request was cancelled"}} = Task.await(cancellation)

    assert_eventually(fn ->
      File.read!(log_path) =~ "notifications/cancelled"
    end)

    assert {:error, %{message: "The MCP request timed out"}} =
             Jido.MCP.call_tool(
               @stdio_endpoint,
               "slow",
               %{"delay_ms" => 100},
               timeout: 20
             )

    assert_eventually(fn -> ExMCP.Client.get_pending_requests(ref.client) == [] end)

    client_monitor = Process.monitor(client_pid)
    supervisor_monitor = Process.monitor(ref.supervisor)

    assert {:ok, ^endpoint} = Jido.MCP.unregister_endpoint(@stdio_endpoint)
    assert_receive {:DOWN, ^client_monitor, :process, ^client_pid, _reason}, 2_000
    assert_receive {:DOWN, ^supervisor_monitor, :process, _pid, _reason}, 2_000
    assert_eventually(fn -> not os_process_alive?(os_pid) end)
  end

  test "streamable HTTP lists and calls tools without sharing credential state" do
    {:ok, _server} =
      Plug.Cowboy.http(
        Jido.MCP.ExMCPIntegrationTest.HTTPServer,
        self(),
        port: 0,
        ref: @http_ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(@http_ref) end)
    port = :ranch.get_port(@http_ref)

    endpoint_a = http_endpoint(@http_endpoint_a, port, "Bearer credential-a")
    endpoint_b = http_endpoint(@http_endpoint_b, port, "Bearer credential-b")

    assert {:ok, ^endpoint_a} = Jido.MCP.register_endpoint(endpoint_a)
    assert {:ok, ^endpoint_b} = Jido.MCP.register_endpoint(endpoint_b)

    assert {:ok, %{data: %{"tools" => [%{"name" => "Bearer credential-a"}]}}} =
             Jido.MCP.list_tools(@http_endpoint_a)

    assert {:ok, %{data: %{"tools" => [%{"name" => "Bearer credential-b"}]}}} =
             Jido.MCP.list_tools(@http_endpoint_b)

    assert {:ok, %{data: %{"content" => [%{"text" => "Bearer credential-a"}]}}} =
             Jido.MCP.call_tool(@http_endpoint_a, "credential", %{})

    assert {:ok, ^endpoint_a, ref_a} = ClientPool.ensure_client(@http_endpoint_a)
    assert {:ok, ^endpoint_b, ref_b} = ClientPool.ensure_client(@http_endpoint_b)
    refute GenServer.whereis(ref_a.client) == GenServer.whereis(ref_b.client)
    refute ref_a.client == ref_b.client

    assert_received {:mcp_http_request, "tools/list", "Bearer credential-a"}
    assert_received {:mcp_http_request, "tools/list", "Bearer credential-b"}
  end

  defp stdio_endpoint(log_path) do
    fixture = Path.expand("support/ex_mcp_stdio_server.fixture", __DIR__)
    jason_ebin = :jason |> :code.lib_dir() |> to_string() |> Path.join("ebin")

    Endpoint.new(@stdio_endpoint, %{
      backend: :ex_mcp,
      transport:
        {:stdio,
         command: System.find_executable("elixir"), args: ["-pa", jason_ebin, fixture, log_path]},
      client_info: %{name: "jido_mcp_test"},
      timeouts: %{request_ms: 10_000}
    })
  end

  defp http_endpoint(id, port, authorization) do
    {:ok, endpoint} =
      Endpoint.new(id, %{
        backend: :ex_mcp,
        transport:
          {:streamable_http,
           base_url: "http://localhost:#{port}/mcp",
           headers: [{"Authorization", authorization}],
           enable_sse: false},
        client_info: %{name: "jido_mcp_test"},
        timeouts: %{request_ms: 2_000}
      })

    endpoint
  end

  defp remove_endpoint(endpoint_id) do
    case ClientPool.fetch_endpoint(endpoint_id) do
      {:ok, _endpoint} -> Jido.MCP.unregister_endpoint(endpoint_id)
      {:error, :unknown_endpoint} -> :ok
    end
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp os_process_alive?(os_pid) when is_integer(os_pid) do
    case System.find_executable("kill") do
      nil ->
        false

      kill ->
        match?(
          {_output, 0},
          System.cmd(kill, ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
        )
    end
  end
end
