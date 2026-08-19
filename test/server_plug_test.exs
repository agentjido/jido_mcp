defmodule Jido.MCP.Server.PlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Jido.MCP.{ClientPool, Endpoint}
  alias Jido.MCP.Server.Plug, as: ServerPlug
  alias Jido.MCP.Server.SessionLimiter

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

  defmodule OtherServer do
    use Jido.MCP.Server,
      name: "other-plug-test",
      version: "1.0.0",
      publish: %{tools: [ContextAction]}
  end

  setup do
    remove_endpoint()
    on_exit(&remove_endpoint/0)
    reset_limiter!()

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
          handler_deadline_ms: 25
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

  test "limits sessions per principal and tenant", %{opts: _opts} do
    opts =
      ServerPlug.init(
        server: Server,
        request_context: fn conn, _request ->
          {:ok,
           %{
             assigns: %{},
             principal_id: conn |> get_req_header("x-principal") |> List.first() || "principal-a",
             tenant_id: conn |> get_req_header("x-tenant") |> List.first() || "tenant-a"
           }}
        end,
        limits: [
          allowed_hosts: ["allowed.example"],
          max_sessions_per_identity: 1,
          idle_session_ttl_ms: 1_000
        ]
      )

    first = initialize_request(opts, "principal-a", "tenant-a", 101)
    assert first.status == 200

    limited = initialize_request(opts, "principal-a", "tenant-a", 102)
    assert limited.status == 429

    independent = initialize_request(opts, "principal-b", "tenant-a", 103)
    assert independent.status == 200
  end

  test "expires an idle limited session and releases a deleted session slot", %{opts: _opts} do
    opts = session_limit_opts(2)
    first = initialize_request(opts, "principal-delete", "tenant-a", 201)
    [session_id] = get_resp_header(first, "mcp-session-id")

    deleted =
      conn(:delete, "/mcp", "")
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "principal-delete")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert deleted.status == 204
    assert initialize_request(opts, "principal-delete", "tenant-a", 202).status == 200

    ttl_opts = session_limit_opts(1)
    initialized = initialize_request(ttl_opts, "principal-ttl", "tenant-a", 203)
    [idle_session_id] = get_resp_header(initialized, "mcp-session-id")
    advance_limiter_clock!(5)

    expired =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 204)))
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "principal-ttl")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("mcp-session-id", idle_session_id)
      |> ServerPlug.call(ttl_opts)

    assert expired.status == 404
  end

  test "admits one concurrent initialize per identity and isolates servers", %{opts: _opts} do
    opts = session_limit_opts(1_000)

    responses =
      301..302
      |> Task.async_stream(
        fn id -> initialize_request(opts, "principal-concurrent", "tenant-a", id) end,
        max_concurrency: 2,
        ordered: false,
        timeout: 2_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert Enum.sort(Enum.map(responses, & &1.status)) == [200, 429]

    other_opts =
      ServerPlug.init(
        server: OtherServer,
        request_context: fn conn, _request ->
          {:ok,
           %{
             assigns: %{},
             principal_id:
               conn |> get_req_header("x-principal") |> List.first() || "principal-concurrent",
             tenant_id: conn |> get_req_header("x-tenant") |> List.first() || "tenant-a"
           }}
        end,
        limits: [
          allowed_hosts: ["allowed.example"],
          max_sessions_per_identity: 1,
          idle_session_ttl_ms: 1_000
        ]
      )

    assert initialize_request(other_opts, "principal-concurrent", "tenant-a", 303).status == 200
  end

  test "supports independent session count and idle TTL limits and releases failed admission", %{
    opts: _opts
  } do
    max_only_opts =
      ServerPlug.init(
        server: Server,
        request_context: &identity_context/2,
        limits: [allowed_hosts: ["allowed.example"], max_sessions_per_identity: 1]
      )

    assert initialize_request(max_only_opts, "principal-max-only", "tenant-a", 351).status == 200
    assert initialize_request(max_only_opts, "principal-max-only", "tenant-a", 352).status == 429

    [stale_session_id] =
      max_only_opts
      |> initialize_request("principal-stale", "tenant-a", 357)
      |> get_resp_header("mcp-session-id")

    ExMCP.SessionManager.terminate_session(stale_session_id)
    assert initialize_request(max_only_opts, "principal-stale", "tenant-a", 358).status == 200

    ttl_only_opts =
      ServerPlug.init(
        server: Server,
        request_context: &identity_context/2,
        limits: [allowed_hosts: ["allowed.example"], idle_session_ttl_ms: 1]
      )

    initialized = initialize_request(ttl_only_opts, "principal-ttl-only", "tenant-a", 353)
    [session_id] = get_resp_header(initialized, "mcp-session-id")
    advance_limiter_clock!(5)

    expired =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 354)))
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "principal-ttl-only")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(ttl_only_opts)

    assert expired.status == 404

    failed =
      conn(:post, "/mcp", Jason.encode!(request("unknown/method", 355)))
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "principal-failure")
      |> put_req_header("x-tenant", "tenant-a")
      |> ServerPlug.call(max_only_opts)

    assert failed.status in 400..499
    assert initialize_request(max_only_opts, "principal-failure", "tenant-a", 356).status == 200
  end

  test "keeps a pending admission through its handler deadline", %{opts: _opts} do
    opts =
      ServerPlug.init(
        server: Server,
        request_context: &identity_context/2,
        limits: [
          allowed_hosts: ["allowed.example"],
          max_sessions_per_identity: 1,
          handler_deadline_ms: 10
        ]
      )

    identity = {"principal-reservation", "tenant-a"}

    assert {:ok, token, []} =
             SessionLimiter.reserve(Server, identity, nil, 1, nil, opts.reservation_ttl_ms)

    advance_limiter_clock!(opts.reservation_ttl_ms - 1)

    assert {:error, :session_limit_exceeded, []} =
             SessionLimiter.reserve(Server, identity, nil, 1, nil, opts.reservation_ttl_ms)

    advance_limiter_clock!(1)

    assert {:ok, _replacement, []} =
             SessionLimiter.reserve(Server, identity, nil, 1, nil, opts.reservation_ttl_ms)

    assert :error = SessionLimiter.bind(token, "untracked-session")
  end

  test "proactively closes idle sessions and does not schedule nil-TTL timers", %{opts: _opts} do
    ttl_opts = session_limit_opts(1)
    initialized = initialize_request(ttl_opts, "principal-proactive", "tenant-a", 371)
    [session_id] = get_resp_header(initialized, "mcp-session-id")
    %{timer_ref: timer_ref, timer_token: timer_token} = :sys.get_state(SessionLimiter)
    assert is_reference(timer_ref)
    assert is_reference(timer_token)

    advance_limiter_clock!(5)
    send(SessionLimiter, {:expire, timer_token})

    assert [] = SessionLimiter.sessions(Server, {"principal-proactive", "tenant-a"})

    assert {:error, :session_not_found} =
             ExMCP.SessionManager.ensure_session(session_id, %{
               principal_id: "principal-proactive",
               tenant_id: "tenant-a"
             })

    follow_up =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 373)))
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "principal-proactive")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(ttl_opts)

    assert follow_up.status == 404

    max_only_opts =
      ServerPlug.init(
        server: Server,
        request_context: &identity_context/2,
        limits: [allowed_hosts: ["allowed.example"], max_sessions_per_identity: 1]
      )

    assert initialize_request(max_only_opts, "principal-no-ttl", "tenant-a", 374).status == 200
    %{timer_ref: nil, timer_token: nil} = :sys.get_state(SessionLimiter)
  end

  test "uses identity-verified host invalidation without exposing rejection details", %{
    opts: _opts
  } do
    owner = self()

    opts =
      ServerPlug.init(
        server: Server,
        request_context: fn conn, _request ->
          principal_id =
            conn |> get_req_header("x-principal") |> List.first() || "principal-owner"

          tenant_id = conn |> get_req_header("x-tenant") |> List.first() || "tenant-a"

          if get_req_header(conn, "x-revoke") == ["true"] do
            {:error,
             %{
               invalidate_session: %{principal_id: principal_id, tenant_id: tenant_id},
               reason: :revoked
             }}
          else
            {:ok, %{assigns: %{}, principal_id: principal_id, tenant_id: tenant_id}}
          end
        end,
        lifecycle: fn event -> send(owner, {:invalidation_lifecycle, event}) end,
        limits: [
          allowed_hosts: ["allowed.example"],
          max_sessions_per_identity: 1,
          idle_session_ttl_ms: 1_000
        ]
      )

    initialized = initialize_request(opts, "principal-owner", "tenant-a", 401)
    [session_id] = get_resp_header(initialized, "mcp-session-id")

    guessed =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 402)))
      |> with_host("allowed.example")
      |> put_req_header("authorization", "Bearer invalid-secret-marker")
      |> put_req_header("x-principal", "principal-attacker")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("x-revoke", "true")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert guessed.status == 401

    assert guessed.resp_body ==
             Jason.encode!(%{"error" => %{"message" => "MCP request rejected"}})

    refute guessed.resp_body =~ "invalid-secret-marker"

    still_active =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 403)))
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "principal-owner")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert still_active.status == 200

    revoked =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 404)))
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "principal-owner")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("x-revoke", "true")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert revoked.status == 401

    assert_receive {:invalidation_lifecycle,
                    %{event: :session_invalidated, session_id: ^session_id, reason: :revoked}}

    terminated =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 405)))
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "principal-owner")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert terminated.status == 404
  end

  test "invalidates a changed principal revision only in the same trusted family", %{opts: _opts} do
    owner = self()

    opts =
      ServerPlug.init(
        server: Server,
        request_context: fn conn, _request ->
          {:ok,
           %{
             assigns: %{},
             principal_id:
               conn |> get_req_header("x-principal") |> List.first() || "grant-a:rev1",
             tenant_id: conn |> get_req_header("x-tenant") |> List.first() || "tenant-a",
             session_family_id: conn |> get_req_header("x-family") |> List.first()
           }}
        end,
        lifecycle: fn event -> send(owner, {:revision_lifecycle, event}) end,
        limits: [allowed_hosts: ["allowed.example"], idle_session_ttl_ms: 1_000]
      )

    initialized = initialize_request(opts, "grant-a:rev1", "tenant-a", "grant-a", 451)
    [session_id] = get_resp_header(initialized, "mcp-session-id")

    changed_revision =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 452)))
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "grant-a:rev2")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("x-family", "grant-a")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert changed_revision.status == 404

    assert_receive {:revision_lifecycle,
                    %{
                      event: :session_invalidated,
                      session_id: ^session_id,
                      reason: :revision_changed
                    }}

    protected = initialize_request(opts, "grant-owner:rev1", "tenant-a", "grant-owner", 453)
    [protected_session_id] = get_resp_header(protected, "mcp-session-id")

    guessed =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 454)))
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "grant-other:rev2")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("x-family", "grant-other")
      |> put_req_header("mcp-session-id", protected_session_id)
      |> ServerPlug.call(opts)

    assert guessed.status == 404

    still_protected =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 455)))
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "grant-owner:rev1")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("x-family", "grant-owner")
      |> put_req_header("mcp-session-id", protected_session_id)
      |> ServerPlug.call(opts)

    assert still_protected.status == 200
  end

  test "invalidates a revoked trusted family without a current principal", %{opts: _opts} do
    owner = self()

    opts =
      ServerPlug.init(
        server: Server,
        request_context: fn conn, _request ->
          tenant_id = conn |> get_req_header("x-tenant") |> List.first() || "tenant-a"
          family_id = conn |> get_req_header("x-family") |> List.first()

          if get_req_header(conn, "x-revoke") == ["true"] do
            {:error,
             %{
               invalidate_session: %{session_family_id: family_id, tenant_id: tenant_id},
               reason: :revoked
             }}
          else
            {:ok,
             %{
               assigns: %{},
               principal_id: conn |> get_req_header("x-principal") |> List.first(),
               tenant_id: tenant_id,
               session_family_id: family_id
             }}
          end
        end,
        lifecycle: fn event -> send(owner, {:family_invalidation_lifecycle, event}) end,
        limits: [allowed_hosts: ["allowed.example"]]
      )

    initialized = initialize_request(opts, "grant-rev1", "tenant-a", "grant-family", 461)
    [session_id] = get_resp_header(initialized, "mcp-session-id")

    attacker =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 462)))
      |> with_host("allowed.example")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("x-family", "other-family")
      |> put_req_header("x-revoke", "true")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert attacker.status == 401

    still_active =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 463)))
      |> with_host("allowed.example")
      |> put_req_header("x-principal", "grant-rev1")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("x-family", "grant-family")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert still_active.status == 200

    revoked =
      conn(:post, "/mcp", Jason.encode!(request("tools/list", 464)))
      |> with_host("allowed.example")
      |> put_req_header("x-tenant", "tenant-a")
      |> put_req_header("x-family", "grant-family")
      |> put_req_header("x-revoke", "true")
      |> put_req_header("mcp-session-id", session_id)
      |> ServerPlug.call(opts)

    assert revoked.status == 401

    assert_receive {:family_invalidation_lifecycle,
                    %{event: :session_invalidated, session_id: ^session_id, reason: :revoked}}
  end

  defp request(method, id, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp with_host(conn, host), do: %{conn | host: host}

  defp initialize_request(opts, principal_id, tenant_id, id) do
    conn(
      :post,
      "/mcp",
      Jason.encode!(request("initialize", id, %{"protocolVersion" => "2025-06-18"}))
    )
    |> with_host("allowed.example")
    |> put_req_header("x-principal", principal_id)
    |> put_req_header("x-tenant", tenant_id)
    |> ServerPlug.call(opts)
  end

  defp initialize_request(opts, principal_id, tenant_id, family_id, id) do
    conn(
      :post,
      "/mcp",
      Jason.encode!(request("initialize", id, %{"protocolVersion" => "2025-06-18"}))
    )
    |> with_host("allowed.example")
    |> put_req_header("x-principal", principal_id)
    |> put_req_header("x-tenant", tenant_id)
    |> put_req_header("x-family", family_id)
    |> ServerPlug.call(opts)
  end

  defp session_limit_opts(ttl_ms) do
    ServerPlug.init(
      server: Server,
      request_context: fn conn, _request ->
        {:ok,
         %{
           assigns: %{},
           principal_id: conn |> get_req_header("x-principal") |> List.first() || "principal-a",
           tenant_id: conn |> get_req_header("x-tenant") |> List.first() || "tenant-a"
         }}
      end,
      limits: [
        allowed_hosts: ["allowed.example"],
        max_sessions_per_identity: 1,
        idle_session_ttl_ms: ttl_ms
      ]
    )
  end

  defp identity_context(conn, _request) do
    {:ok,
     %{
       assigns: %{},
       principal_id: conn |> get_req_header("x-principal") |> List.first() || "principal-a",
       tenant_id: conn |> get_req_header("x-tenant") |> List.first() || "tenant-a"
     }}
  end

  defp reset_limiter! do
    :sys.replace_state(SessionLimiter, fn state ->
      if state.timer_ref, do: Process.cancel_timer(state.timer_ref, async: true, info: false)

      %{
        sessions: %{},
        reservations: %{},
        clock_offset_ms: 0,
        timer_ref: nil,
        timer_token: nil
      }
    end)
  end

  defp advance_limiter_clock!(milliseconds) do
    :sys.replace_state(SessionLimiter, fn state ->
      %{state | clock_offset_ms: state.clock_offset_ms + milliseconds}
    end)
  end

  defp remove_endpoint do
    case ClientPool.fetch_endpoint(@http_endpoint) do
      {:ok, _endpoint} -> Jido.MCP.unregister_endpoint(@http_endpoint)
      {:error, :unknown_endpoint} -> :ok
    end
  end
end
