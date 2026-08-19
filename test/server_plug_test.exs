defmodule Jido.MCP.Server.PlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Jido.MCP.{ClientPool, Endpoint}
  alias Jido.MCP.Server.Plug, as: ServerPlug

  @secret "Bearer jido-mcp-server-plug-secret-marker"
  @http_endpoint :server_plug_http_client
  @http_ref Jido.MCP.Server.PlugTest.HTTPListener

  defmodule ContextAction do
    use Jido.Action,
      name: "context",
      description: "Returns the host context",
      schema: []

    @impl true
    def run(_params, context) do
      {:ok, %{assigns: context.assigns, transport: context.transport}}
    end
  end

  defmodule SlowAction do
    use Jido.Action,
      name: "slow",
      description: "Waits for the request deadline",
      schema: []

    @impl true
    def run(_params, _context) do
      Process.sleep(50)
      {:ok, %{ok: true}}
    end
  end

  defmodule Server do
    use Jido.MCP.Server,
      name: "plug-test",
      version: "1.0.0",
      publish: %{tools: [ContextAction, SlowAction]}
  end

  setup do
    remove_endpoint()
    on_exit(&remove_endpoint/0)

    owner = self()

    opts =
      ServerPlug.init(
        server: Server,
        request_context: fn conn, _request ->
          principal_id = conn |> get_req_header("x-principal") |> List.first() || "principal-a"
          tenant_id = conn |> get_req_header("x-tenant") |> List.first() || "tenant-a"

          {:ok,
           %{
             assigns: %{request_marker: "redacted-context", authorization: @secret},
             principal_id: principal_id,
             tenant_id: tenant_id
           }}
        end,
        lifecycle: fn event -> send(owner, {:server_lifecycle, event}) end,
        limits: [
          allowed_hosts: ["allowed.example"],
          allowed_origins: ["https://allowed.example"],
          body_bytes: 1_024,
          response_bytes: 20_000,
          handler_deadline_ms: 10
        ]
      )

    %{opts: opts}
  end

  test "the public HTTP client initializes and lists the allowlisted tools" do
    opts = [
      server: Server,
      request_context: fn _conn, _request ->
        {:ok, %{assigns: %{request_marker: "http-client"}, principal_id: "principal-a"}}
      end,
      limits: [
        allowed_hosts: ["localhost", "127.0.0.1"],
        allowed_origins: :any,
        response_bytes: 20_000
      ]
    ]

    {:ok, _server} = Plug.Cowboy.http(ServerPlug, opts, port: 0, ref: @http_ref)
    on_exit(fn -> Plug.Cowboy.shutdown(@http_ref) end)

    port = :ranch.get_port(@http_ref)

    {:ok, endpoint} =
      Endpoint.new(@http_endpoint, %{
        transport:
          {:streamable_http,
           base_url: "http://localhost:#{port}",
           mcp_path: "/mcp",
           headers: [{"Authorization", @secret}]},
        client_info: %{name: "jido_mcp_test"},
        timeouts: %{request_ms: 2_000}
      })

    assert {:ok, ^endpoint} = Jido.MCP.register_endpoint(endpoint)

    assert {:ok, %{data: %{"tools" => tools}}} = Jido.MCP.list_tools(@http_endpoint)
    assert Enum.map(tools, & &1["name"]) |> Enum.sort() == ["context", "slow"]
  end

  test "binds a session to the current principal and passes only redacted assigns", %{opts: opts} do
    initialize = request("initialize", 1, %{"protocolVersion" => "2025-06-18"})

    response =
      conn(:post, "/mcp", Jason.encode!(initialize))
      |> with_host("allowed.example")
      |> put_req_header("authorization", @secret)
      |> put_req_header("x-principal", "principal-a")
      |> ServerPlug.call(opts)

    assert response.status == 200
    [session_id] = get_resp_header(response, "mcp-session-id")

    response =
      conn(
        :post,
        "/mcp",
        Jason.encode!(request("tools/call", 2, %{"name" => "context", "arguments" => %{}}))
      )
      |> with_host("allowed.example")
      |> put_req_header("authorization", @secret)
      |> put_req_header("x-principal", "principal-a")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert response.status == 200
    refute response.resp_body =~ @secret
    assert response.resp_body =~ "redacted-context"
    assert response.resp_body =~ "principal-a"
    assert response.resp_body =~ "tenant-a"

    rejected =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 3)))
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "principal-b")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert rejected.status == 404
    assert rejected.resp_body =~ "Session not found"
  end

  test "deletes sessions and calls lifecycle hooks", %{opts: opts} do
    response =
      conn(
        :post,
        "/mcp",
        Jason.encode!(request("initialize", 1, %{"protocolVersion" => "2025-06-18"}))
      )
      |> with_host("allowed.example")
      |> ServerPlug.call(opts)

    [session_id] = get_resp_header(response, "mcp-session-id")

    deleted =
      conn(:delete, "/mcp", "")
      |> with_host("allowed.example")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert deleted.status == 204
    assert_receive {:server_lifecycle, %{event: :session_deleted, session_id: ^session_id}}

    rejected =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 2)))
      |> with_host("allowed.example")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert rejected.status == 404
  end

  test "enforces host, origin, body, response, and handler deadline limits", %{opts: opts} do
    rejected_host =
      conn(
        :post,
        "/mcp",
        Jason.encode!(request("initialize", 1, %{"protocolVersion" => "2025-06-18"}))
      )
      |> with_host("denied.example")
      |> ServerPlug.call(opts)

    assert rejected_host.status == 421

    rejected_origin =
      conn(
        :post,
        "/mcp",
        Jason.encode!(request("initialize", 2, %{"protocolVersion" => "2025-06-18"}))
      )
      |> with_host("allowed.example")
      |> put_req_header("origin", "https://denied.example")
      |> ServerPlug.call(opts)

    assert rejected_origin.status == 403

    too_large =
      conn(:post, "/mcp", String.duplicate("x", 1_025))
      |> with_host("allowed.example")
      |> ServerPlug.call(opts)

    assert too_large.status == 413

    initialized =
      conn(
        :post,
        "/mcp",
        Jason.encode!(request("initialize", 3, %{"protocolVersion" => "2025-06-18"}))
      )
      |> with_host("allowed.example")
      |> ServerPlug.call(opts)

    [session_id] = get_resp_header(initialized, "mcp-session-id")

    timeout =
      conn(
        :post,
        "/mcp",
        Jason.encode!(request("tools/call", 4, %{"name" => "slow", "arguments" => %{}}))
      )
      |> with_host("allowed.example")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert timeout.status == 200
    timeout_body = Jason.decode!(timeout.resp_body)
    assert timeout_body["error"]

    response_opts =
      ServerPlug.init(
        server: Server,
        request_context: fn _conn, _request -> {:ok, %{assigns: %{}}} end,
        limits: [allowed_hosts: ["allowed.example"], response_bytes: 32]
      )

    response_too_large =
      conn(
        :post,
        "/mcp",
        Jason.encode!(request("initialize", 5, %{"protocolVersion" => "2025-06-18"}))
      )
      |> with_host("allowed.example")
      |> ServerPlug.call(response_opts)

    assert response_too_large.status == 413
    assert response_too_large.resp_body =~ "Response body too large"
  end

  test "rejects unsafe host options with a stable error" do
    assert {:error, %{reason: :invalid_options, details: %{field: :limits}}} =
             ServerPlug.validate_options(
               server: Server,
               request_context: fn _conn -> {:ok, %{assigns: %{}}} end,
               limits: [body_bytes: :infinity]
             )
  end

  defp request(method, id, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp with_host(conn, host), do: %{conn | host: host}

  defp remove_endpoint do
    case ClientPool.fetch_endpoint(@http_endpoint) do
      {:ok, _endpoint} -> Jido.MCP.unregister_endpoint(@http_endpoint)
      {:error, :unknown_endpoint} -> :ok
    end
  end
end
