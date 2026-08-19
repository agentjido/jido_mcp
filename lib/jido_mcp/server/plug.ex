defmodule Jido.MCP.Server.Plug do
  @moduledoc """
  Stable Plug host adapter for a `Jido.MCP.Server`.

  The host owns authentication and authorization. It supplies a
  `:request_context` callback that runs for every `POST` and `DELETE` before
  ExMCP can allocate or resolve a session. The callback returns only redacted
  assigns plus stable principal and tenant identifiers. The adapter never puts
  the request connection or its headers into a Jido action context.

  ## Example

      forward "/mcp", Jido.MCP.Server.Plug,
        server: MyApp.MCPServer,
        request_context: fn conn, _request ->
          with {:ok, grant} <- MyApp.Grants.authorize(conn) do
            {:ok,
             %{
               principal_id: grant.id,
               tenant_id: grant.tenant_id,
               assigns: %{grant_id: grant.id, grant_revision: grant.revision}
             }}
          end
        end,
        limits: [
          allowed_hosts: ["mcp.example.com"],
          allowed_origins: ["https://app.example.com"],
          body_bytes: 1_000_000,
          response_bytes: 1_000_000,
          handler_deadline_ms: 10_000
        ]

  `:request_context` is deliberately required. Authentication only during
  `initialize` is unsafe because a revoked identity could keep using a session.
  """

  @behaviour Plug

  import Plug.Conn

  @default_limits %{
    allowed_hosts: :any,
    allowed_origins: [],
    body_bytes: 1_000_000,
    response_bytes: 1_000_000,
    handler_deadline_ms: 10_000
  }

  @secret_key_fragments ["authorization", "bearer", "credential", "password", "secret", "token"]

  @type host_context :: %{
          required(:assigns) => map(),
          optional(:principal_id) => String.t() | nil,
          optional(:tenant_id) => String.t() | nil
        }

  @doc """
  Validates options without starting a Plug.

  This function returns a stable, secret-free error shape. `init/1` raises an
  `ArgumentError` with the same public reason when validation fails, as Plug
  initialization requires a valid return value.
  """
  @spec validate_options(keyword()) :: :ok | {:error, map()}
  def validate_options(opts) when is_list(opts) do
    with :ok <- validate_known_options(opts),
         :ok <- validate_server(Keyword.get(opts, :server)),
         :ok <- validate_request_context(Keyword.get(opts, :request_context)),
         :ok <- validate_lifecycle(Keyword.get(opts, :lifecycle)),
         :ok <-
           validate_positive(
             Keyword.get(opts, :lifecycle_timeout_ms, 1_000),
             :lifecycle_timeout_ms
           ),
         {:ok, _limits} <- normalize_limits(Keyword.get(opts, :limits, [])),
         :ok <- validate_protocol_mode(Keyword.get(opts, :protocol_mode)) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  def validate_options(_opts), do: invalid_options(:options)

  @impl Plug
  @spec init(keyword()) :: map()
  def init(opts) do
    case validate_options(opts) do
      :ok ->
        {:ok, limits} = normalize_limits(Keyword.get(opts, :limits, []))
        server = Keyword.fetch!(opts, :server)

        ex_mcp_opts =
          [
            handler: server,
            server_info: server.__server_info__(),
            server_capabilities: server.__server_capabilities__(),
            handler_opts: &handler_opts/2,
            principal_id: &principal_id/2,
            tenant_id: &tenant_id/2,
            allowed_hosts: limits.allowed_hosts,
            allowed_origins: limits.allowed_origins,
            body_limit: limits.body_bytes,
            handler_call_timeout: limits.handler_deadline_ms,
            protocol_mode: Keyword.get(opts, :protocol_mode)
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> ExMCP.HttpPlug.init()

        %{
          ex_mcp_opts: ex_mcp_opts,
          request_context: Keyword.fetch!(opts, :request_context),
          lifecycle: Keyword.get(opts, :lifecycle),
          lifecycle_timeout_ms: Keyword.get(opts, :lifecycle_timeout_ms, 1_000),
          response_bytes: limits.response_bytes
        }

      {:error, %{details: %{field: field}}} ->
        raise ArgumentError, "invalid Jido.MCP.Server.Plug option: #{field}"
    end
  end

  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, opts) do
    if conn.method in ["POST", "DELETE"] do
      request = request_descriptor(conn)

      case resolve_request_context(opts.request_context, conn, request) do
        {:ok, context} ->
          conn
          |> assign(:jido_mcp_host_context, context)
          |> register_before_send(&limit_response(&1, opts.response_bytes))
          |> call_ex_mcp(opts, request, context)

        {:error, _reason} ->
          emit_lifecycle(opts, %{event: :request_rejected, request: request})
          rejected_response(conn)
      end
    else
      conn
      |> register_before_send(&limit_response(&1, opts.response_bytes))
      |> ExMCP.HttpPlug.call(opts.ex_mcp_opts)
    end
  end

  defp call_ex_mcp(conn, opts, request, context) do
    result = ExMCP.HttpPlug.call(conn, opts.ex_mcp_opts)

    if request.method == "DELETE" and result.status == 204 do
      emit_lifecycle(opts, %{
        event: :session_deleted,
        session_id: request.session_id,
        principal_id: context.principal_id,
        tenant_id: context.tenant_id
      })
    end

    emit_lifecycle(opts, %{
      event: :request_finished,
      request: request,
      status: result.status,
      principal_id: context.principal_id,
      tenant_id: context.tenant_id
    })

    result
  rescue
    _exception ->
      emit_lifecycle(opts, %{event: :request_failed, request: request})
      failed_response(conn)
  catch
    _kind, _reason ->
      emit_lifecycle(opts, %{event: :request_failed, request: request})
      failed_response(conn)
  end

  defp handler_opts(conn, _request) do
    context = Map.fetch!(conn.assigns, :jido_mcp_host_context)
    %{assigns: context.assigns}
  end

  defp principal_id(conn, _request), do: context_value(conn, :principal_id)
  defp tenant_id(conn, _request), do: context_value(conn, :tenant_id)

  defp context_value(conn, key) do
    conn.assigns
    |> Map.fetch!(:jido_mcp_host_context)
    |> Map.fetch!(key)
  end

  defp resolve_request_context(callback, conn, request) do
    callback
    |> invoke_request_context(conn, request)
    |> normalize_host_context()
  rescue
    _exception -> {:error, :request_context_failed}
  catch
    _kind, _reason -> {:error, :request_context_failed}
  end

  defp invoke_request_context(callback, conn, request) when is_function(callback, 2),
    do: callback.(conn, request)

  defp invoke_request_context(callback, conn, _request) when is_function(callback, 1),
    do: callback.(conn)

  defp normalize_host_context({:ok, context}), do: normalize_host_context(context)

  defp normalize_host_context(%{} = context) do
    raw_assigns = Map.get(context, :assigns, %{})
    assigns = sanitize_assigns(raw_assigns)
    principal_id = Map.get(context, :principal_id)
    tenant_id = Map.get(context, :tenant_id)

    if is_map(raw_assigns) and valid_identity?(principal_id) and valid_identity?(tenant_id) do
      {:ok, %{assigns: assigns, principal_id: principal_id, tenant_id: tenant_id}}
    else
      {:error, :invalid_request_context}
    end
  end

  defp normalize_host_context(_other), do: {:error, :invalid_request_context}

  defp valid_identity?(nil), do: true
  defp valid_identity?(identity), do: is_binary(identity) and byte_size(identity) in 1..512

  defp sanitize_assigns(assigns) when is_map(assigns) do
    assigns
    |> Enum.reject(fn {key, _value} -> secret_key?(key) end)
    |> Map.new(fn {key, value} -> {key, sanitize_assign_value(value)} end)
  end

  defp sanitize_assigns(_assigns), do: %{}

  defp sanitize_assign_value(%{} = value), do: sanitize_assigns(value)

  defp sanitize_assign_value(value) when is_list(value),
    do: Enum.map(value, &sanitize_assign_value/1)

  defp sanitize_assign_value(value), do: value

  defp secret_key?(key) when is_atom(key) or is_binary(key) do
    normalized = key |> to_string() |> String.downcase()
    Enum.any?(@secret_key_fragments, &String.contains?(normalized, &1))
  end

  defp secret_key?(_key), do: false

  defp limit_response(conn, max_bytes) do
    if byte_size(conn.resp_body || "") > max_bytes do
      terminate_response_session(conn)

      conn
      |> delete_resp_header("mcp-session-id")
      |> put_resp_content_type("application/json")
      |> resp(413, Jason.encode!(%{"error" => %{"message" => "Response body too large"}}))
    else
      conn
    end
  end

  defp terminate_response_session(conn) do
    case get_resp_header(conn, "mcp-session-id") do
      [session_id | _rest] ->
        ExMCP.SessionManager.terminate_session(session_id)
        :ok

      [] ->
        :ok
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp request_descriptor(conn) do
    %{
      method: conn.method,
      path: conn.request_path,
      session_id: conn |> get_req_header("mcp-session-id") |> List.first()
    }
  end

  defp rejected_response(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{"error" => %{"message" => "MCP request rejected"}}))
  end

  defp failed_response(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(500, Jason.encode!(%{"error" => %{"message" => "MCP server failure"}}))
  end

  defp emit_lifecycle(%{lifecycle: nil}, _event), do: :ok

  defp emit_lifecycle(opts, event) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        try do
          opts.lifecycle.(event)
        rescue
          _exception -> :ok
        catch
          _kind, _reason -> :ok
        after
          send(parent, {ref, :done})
        end
      end)

    receive do
      {^ref, :done} -> :ok
    after
      opts.lifecycle_timeout_ms ->
        Process.exit(pid, :kill)
        :ok
    end
  end

  defp validate_known_options(opts) do
    allowed = [
      :server,
      :request_context,
      :lifecycle,
      :lifecycle_timeout_ms,
      :limits,
      :protocol_mode
    ]

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)),
      do: :ok,
      else: invalid_options(:options)
  end

  defp validate_server(server) when is_atom(server) do
    if function_exported?(server, :__server_info__, 0) and
         function_exported?(server, :__server_capabilities__, 0),
       do: :ok,
       else: invalid_options(:server)
  end

  defp validate_server(_server), do: invalid_options(:server)

  defp validate_request_context(callback) when is_function(callback, 1), do: :ok
  defp validate_request_context(callback) when is_function(callback, 2), do: :ok
  defp validate_request_context(_callback), do: invalid_options(:request_context)

  defp validate_lifecycle(nil), do: :ok
  defp validate_lifecycle(callback) when is_function(callback, 1), do: :ok
  defp validate_lifecycle(_callback), do: invalid_options(:lifecycle)

  defp validate_protocol_mode(nil), do: :ok

  defp validate_protocol_mode(mode)
       when mode in [:legacy_only, :modern_only, :prefer_legacy, :prefer_modern],
       do: :ok

  defp validate_protocol_mode(_mode), do: invalid_options(:protocol_mode)

  defp normalize_limits(limits) when is_list(limits) do
    if Keyword.keyword?(limits) do
      allowed = Map.keys(@default_limits)

      if Enum.all?(Keyword.keys(limits), &(&1 in allowed)) do
        normalized = Map.merge(@default_limits, Map.new(limits))

        with :ok <- validate_allowed_hosts(normalized.allowed_hosts),
             :ok <- validate_allowed_origins(normalized.allowed_origins),
             :ok <- validate_positive(normalized.body_bytes, :limits),
             :ok <- validate_positive(normalized.response_bytes, :limits),
             :ok <- validate_positive(normalized.handler_deadline_ms, :limits) do
          {:ok, normalized}
        end
      else
        invalid_options(:limits)
      end
    else
      invalid_options(:limits)
    end
  end

  defp normalize_limits(_limits), do: invalid_options(:limits)

  defp validate_allowed_hosts(:any), do: :ok

  defp validate_allowed_hosts(hosts) when is_list(hosts) and hosts != [] do
    if Enum.all?(hosts, &(is_binary(&1) and &1 != "")), do: :ok, else: invalid_options(:limits)
  end

  defp validate_allowed_hosts(_hosts), do: invalid_options(:limits)

  defp validate_allowed_origins(:any), do: :ok

  defp validate_allowed_origins(origins) when is_list(origins) do
    if Enum.all?(origins, &(is_binary(&1) and &1 != "")), do: :ok, else: invalid_options(:limits)
  end

  defp validate_allowed_origins(_origins), do: invalid_options(:limits)

  defp validate_positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(_value, field), do: invalid_options(field)

  defp invalid_options(field), do: {:error, %{reason: :invalid_options, details: %{field: field}}}
end
