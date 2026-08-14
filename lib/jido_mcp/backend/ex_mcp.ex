defmodule Jido.MCP.Backend.ExMCP do
  @moduledoc false

  @behaviour Jido.MCP.Backend

  alias ExMCP.Error
  alias Jido.MCP.Endpoint

  @protected_backend_options [
    :capabilities,
    :cd,
    :command,
    :env,
    :endpoint,
    :environment_policy,
    :fallback_strategy,
    :handshake_timeout,
    :headers,
    :health_check_interval,
    :max_reconnect_attempts,
    :max_retries,
    :max_frame_bytes,
    :max_request_bytes,
    :max_response_bytes,
    :max_stream_buffer_bytes,
    :name,
    :protocol_version,
    :reconnect,
    :reconnect_backoff,
    :reliability,
    :request_timeout,
    :retry_interval,
    :retry_policy,
    :server,
    :timeout,
    :transport,
    :transports,
    :url,
    :use_sse
  ]

  @finite_timeout_options [
    :timeout,
    :request_timeout,
    :handshake_timeout,
    :stream_handshake_timeout,
    :stream_idle_timeout,
    :dns_timeout_ms,
    :max_retry_delay
  ]

  @impl true
  def child_spec(%Endpoint{} = endpoint, ref) do
    with {:ok, client_opts} <- client_options(endpoint, ref) do
      children = [
        %{id: ExMCP.Client, start: {ExMCP.Client, :start_link, [client_opts]}}
      ]

      {:ok,
       %{
         id: {:mcp_client, endpoint.id},
         start:
           {Supervisor, :start_link, [children, [strategy: :one_for_one, name: ref.supervisor]]},
         type: :supervisor,
         restart: :transient,
         shutdown: 10_000
       }}
    end
  end

  @doc false
  @spec client_options(Endpoint.t(), Jido.MCP.Backend.client_ref()) ::
          {:ok, keyword()} | {:error, term()}
  def client_options(%Endpoint{} = endpoint, ref) do
    with :ok <- validate_backend_options(endpoint.backend_options),
         {:ok, transport_opts} <- transport_options(endpoint.transport),
         :ok <- validate_finite_timeouts(transport_opts) do
      base_opts = [
        name: ref.client,
        capabilities: endpoint.capabilities,
        protocol_version: endpoint.protocol_version,
        protocol_mode: default_protocol_mode(endpoint.protocol_version),
        timeout: endpoint.timeouts.request_ms,
        request_timeout: endpoint.timeouts.request_ms,
        handshake_timeout: endpoint.timeouts.request_ms,
        health_check_interval: nil,
        reconnect: false,
        retry_policy: []
      ]

      opts =
        base_opts
        |> Keyword.merge(transport_opts)
        |> Keyword.merge(endpoint.backend_options)
        |> Keyword.drop([
          :transports,
          :fallback_strategy,
          :max_retries,
          :retry_interval,
          :reliability
        ])
        |> Keyword.put(:name, ref.client)
        |> Keyword.put(:transport, transport_opts[:transport])
        |> Keyword.put(:capabilities, endpoint.capabilities)
        |> Keyword.put(:protocol_version, endpoint.protocol_version)
        |> Keyword.put(:timeout, endpoint.timeouts.request_ms)
        |> Keyword.put(:request_timeout, endpoint.timeouts.request_ms)
        |> Keyword.put(:handshake_timeout, endpoint.timeouts.request_ms)
        |> Keyword.put(:health_check_interval, nil)
        |> Keyword.put(:reconnect, false)
        |> Keyword.put(:retry_policy, [])

      {:ok, opts}
    end
  end

  @impl true
  def await_ready(%{client: client}, timeout) do
    case GenServer.call(client, :get_status, timeout) do
      {:ok, %{connection_status: :ready}} -> :ok
      {:ok, _status} -> {:error, :client_not_ready}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, {:timeout, _} -> {:error, :client_not_ready}
    :exit, {:noproc, _} -> {:error, :client_not_started}
    :exit, _reason -> {:error, :client_not_ready}
  end

  @impl true
  def sanitize_start_error({:invalid_transport_options, field}) when is_atom(field),
    do: {:invalid_transport_options, field}

  def sanitize_start_error({:unsupported_transport_option, option}) when is_atom(option),
    do: {:unsupported_transport_option, option}

  def sanitize_start_error({:unsupported_transport, transport, :ex_mcp})
      when is_atom(transport),
      do: {:unsupported_transport, transport, :ex_mcp}

  def sanitize_start_error({:protected_backend_option, option}) when is_atom(option),
    do: {:protected_backend_option, option}

  def sanitize_start_error(:handshake_timeout), do: :client_not_ready
  def sanitize_start_error({:connection_error, _details}), do: :connection_failed

  def sanitize_start_error({:initialize_error, %{"code" => code}}) when is_integer(code),
    do: {:initialize_error, code}

  def sanitize_start_error(_reason), do: :client_start_failed

  @impl true
  def list_tools(client, opts) do
    request(fn ->
      with {:ok, opts} <- safe_opts(opts) do
        ExMCP.Client.list_tools(client, opts)
      end
    end)
  end

  @impl true
  def call_tool(client, tool_name, arguments, opts) do
    request(fn ->
      with {:ok, opts} <- tool_opts(opts) do
        ExMCP.Client.call_tool(client, tool_name, arguments, opts)
      end
    end)
  end

  @impl true
  def list_resources(client, opts) do
    request(fn ->
      with {:ok, opts} <- safe_opts(opts) do
        ExMCP.Client.list_resources(client, opts)
      end
    end)
  end

  @impl true
  def list_resource_templates(client, opts) do
    request(fn ->
      with {:ok, opts} <- safe_opts(opts) do
        ExMCP.Client.list_resource_templates(client, opts)
      end
    end)
  end

  @impl true
  def read_resource(client, uri, opts) do
    request(fn ->
      with {:ok, opts} <- safe_opts(opts) do
        ExMCP.Client.read_resource(client, uri, opts)
      end
    end)
  end

  @impl true
  def list_prompts(client, opts) do
    request(fn ->
      with {:ok, opts} <- safe_opts(opts) do
        ExMCP.Client.list_prompts(client, opts)
      end
    end)
  end

  @impl true
  def get_prompt(client, prompt_name, arguments, opts) do
    request(fn ->
      with {:ok, opts} <- safe_opts(opts) do
        ExMCP.Client.get_prompt(client, prompt_name, arguments, opts)
      end
    end)
  end

  defp transport_options({:stdio, opts}) do
    with {:ok, command} <- stdio_command(opts),
         {:ok, cwd} <- stdio_cwd(Keyword.get(opts, :cwd)),
         {:ok, env} <- stdio_env(Keyword.get(opts, :env)) do
      opts =
        opts
        |> Keyword.drop([:args, :cwd, :command, :env])
        |> Keyword.put(:transport, :stdio)
        |> Keyword.put(:command, command)
        |> maybe_put(:cd, cwd)
        |> maybe_put(:env, env)

      {:ok, opts}
    end
  end

  defp transport_options({:streamable_http, opts}) do
    base_url = Keyword.get(opts, :base_url)
    mcp_path = Keyword.get(opts, :mcp_path, "/mcp")
    headers = Keyword.get(opts, :headers, [])

    with :ok <- validate_http_base_url(base_url),
         :ok <- validate_mcp_path(mcp_path),
         :ok <- validate_headers(headers) do
      mapped =
        opts
        |> Keyword.drop([:base_url, :mcp_path, :enable_sse, :finch_name])
        |> Keyword.put(:transport, :http)
        |> Keyword.put(:url, base_url)
        |> Keyword.put(:endpoint, mcp_path)
        |> maybe_put(:use_sse, Keyword.get(opts, :enable_sse))

      {:ok, mapped}
    end
  end

  defp transport_options({:beam, opts}) do
    server = Keyword.get(opts, :server)

    if is_pid(server) and Process.alive?(server) do
      {:ok, Keyword.put(opts, :transport, :beam)}
    else
      {:error, {:invalid_transport_options, :server}}
    end
  end

  defp transport_options({:sse, _opts}),
    do: {:error, {:unsupported_transport, :sse, :ex_mcp}}

  defp transport_options({transport, _opts}),
    do: {:error, {:unsupported_transport, transport, :ex_mcp}}

  defp stdio_command(opts) do
    command = Keyword.get(opts, :command)
    args = Keyword.get(opts, :args, []) || []

    with {:ok, parts} <- command_parts(command, args),
         :ok <- validate_command_parts(parts) do
      {:ok, parts}
    end
  end

  defp command_parts(command, args) when is_binary(command) and is_list(args),
    do: {:ok, [command | args]}

  defp command_parts(command, args) when is_list(command) and is_list(args),
    do: {:ok, command ++ args}

  defp command_parts(_command, _args), do: {:error, {:invalid_transport_options, :command}}

  defp validate_command_parts([executable | _rest] = parts)
       when is_binary(executable) and executable != "" do
    if Enum.all?(parts, &valid_command_part?/1),
      do: :ok,
      else: {:error, {:invalid_transport_options, :command}}
  end

  defp validate_command_parts(_parts),
    do: {:error, {:invalid_transport_options, :command}}

  defp valid_command_part?(part),
    do: is_binary(part) and not String.contains?(part, <<0>>)

  defp stdio_cwd(nil), do: {:ok, nil}

  defp stdio_cwd(cwd) when is_binary(cwd) and cwd != "" do
    if String.contains?(cwd, <<0>>),
      do: {:error, {:invalid_transport_options, :cwd}},
      else: {:ok, cwd}
  end

  defp stdio_cwd(_cwd), do: {:error, {:invalid_transport_options, :cwd}}

  defp stdio_env(nil), do: {:ok, nil}
  defp stdio_env(env) when is_list(env), do: normalize_env_entries(env)

  defp stdio_env(env) when is_map(env) do
    env
    |> Map.to_list()
    |> normalize_env_entries()
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, &elem(&1, 0))}
      error -> error
    end
  end

  defp stdio_env(_env), do: {:error, {:invalid_transport_options, :env}}

  defp normalize_env_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      {name, value}, {:ok, acc} ->
        case normalize_env_entry(name, value) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          :error -> {:halt, {:error, {:invalid_transport_options, :env}}}
        end

      _entry, _acc ->
        {:halt, {:error, {:invalid_transport_options, :env}}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_env_entry(name, value) when is_binary(name) or is_atom(name) do
    name = to_string(name)

    if valid_env_name?(name) and (is_binary(value) or value == false),
      do: {:ok, {name, value}},
      else: :error
  end

  defp normalize_env_entry(_name, _value), do: :error

  defp valid_env_name?(name) do
    name != "" and not String.contains?(name, ["=", <<0>>])
  end

  defp default_protocol_mode("2026-" <> _rest), do: :modern_only
  defp default_protocol_mode(_version), do: :legacy_only

  defp safe_opts(opts) do
    with :ok <- validate_request_opts(opts) do
      {:ok,
       opts
       |> Keyword.put(:format, :map)
       |> Keyword.put(:retry_policy, false)
       |> Keyword.put(:http_stream_retry, :safe_only)}
    end
  end

  defp tool_opts(opts) do
    with {:ok, opts} <- safe_opts(opts) do
      {:ok, Keyword.put_new(opts, :retry_safe, false)}
    end
  end

  defp validate_request_opts(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_request_option, :options}}

      Keyword.has_key?(opts, :timeout) and not positive_integer?(opts[:timeout]) ->
        {:error, {:invalid_request_option, :timeout}}

      Keyword.has_key?(opts, :retry_safe) and not is_boolean(opts[:retry_safe]) ->
        {:error, {:invalid_request_option, :retry_safe}}

      true ->
        :ok
    end
  end

  defp validate_request_opts(_opts), do: {:error, {:invalid_request_option, :options}}

  defp request(fun) do
    fun.()
    |> sanitize_result()
  rescue
    _error -> {:error, public_error(:request_failed)}
  catch
    _kind, _reason -> {:error, public_error(:request_failed)}
  end

  defp sanitize_result({:ok, _response} = result), do: result
  defp sanitize_result({:error, reason}), do: {:error, public_error(reason)}
  defp sanitize_result(other), do: {:error, public_error({:invalid_backend_response, other})}

  defp public_error(%Error.TransportError{reason: :outcome_unknown}) do
    %{
      reason: :outcome_unknown,
      message: "The MCP tool outcome is unknown because response delivery was interrupted",
      details: %{delivery: :unknown}
    }
  end

  defp public_error(%Error.TransportError{reason: reason}) do
    %{reason: safe_reason(reason), message: "The MCP transport request failed", details: %{}}
  end

  defp public_error(%Error.ProtocolError{code: code}) do
    protocol_error(code)
  end

  defp public_error(%Error.ValidationError{field: field}) do
    %{
      reason: :invalid_params,
      message: "The MCP request validation failed",
      details: %{field: safe_field(field)}
    }
  end

  defp public_error(%Error.ToolError{}),
    do: %{reason: :tool_error, message: "The MCP tool request failed", details: %{}}

  defp public_error(%Error.ResourceError{}),
    do: %{reason: :protocol_error, message: "The MCP resource request failed", details: %{}}

  defp public_error(%Error{code: code}) do
    protocol_error(code)
  end

  defp public_error(%{"code" => code}) when is_integer(code) do
    protocol_error(code)
  end

  defp public_error({:invalid_request_option, field}) when is_atom(field) do
    %{
      reason: :invalid_params,
      message: "The MCP request options are invalid",
      details: %{field: field}
    }
  end

  defp public_error(:timeout),
    do: %{reason: :timeout, message: "The MCP request timed out", details: %{}}

  defp public_error(:cancelled),
    do: %{reason: :cancelled, message: "The MCP request was cancelled", details: %{}}

  defp public_error(:not_connected),
    do: %{reason: :not_connected, message: "The MCP client is not connected", details: %{}}

  defp public_error(_reason),
    do: %{reason: :request_failed, message: "The MCP request failed", details: %{}}

  defp protocol_error(code) when is_integer(code) do
    %{
      reason: protocol_reason(code),
      message: "The MCP protocol request failed",
      details: %{code: code}
    }
  end

  defp protocol_error(_code) do
    %{reason: :protocol_error, message: "The MCP protocol request failed", details: %{}}
  end

  defp protocol_reason(-32_700), do: :parse_error
  defp protocol_reason(-32_600), do: :invalid_request
  defp protocol_reason(-32_601), do: :method_not_found
  defp protocol_reason(-32_602), do: :invalid_params
  defp protocol_reason(_code), do: :protocol_error

  defp safe_reason(reason) when reason in [:closed, :timeout, :not_connected], do: reason
  defp safe_reason(_reason), do: :transport_error

  defp safe_field(field) when is_atom(field) or is_binary(field), do: field
  defp safe_field(_field), do: :request

  defp validate_backend_options(opts) do
    case Enum.find(Keyword.keys(opts), &(&1 in @protected_backend_options)) do
      nil -> :ok
      option -> {:error, {:protected_backend_option, option}}
    end
  end

  defp validate_finite_timeouts(opts) do
    case Enum.find(@finite_timeout_options, fn key ->
           Keyword.has_key?(opts, key) and not positive_integer?(opts[key])
         end) do
      nil -> :ok
      option -> {:error, {:invalid_transport_options, option}}
    end
  end

  defp validate_http_base_url(base_url) when is_binary(base_url) and base_url != "" do
    case URI.new(base_url) do
      {:ok, %URI{} = uri} ->
        validate_http_uri(uri)

      {:error, _reason} ->
        {:error, {:invalid_transport_options, :base_url}}
    end
  end

  defp validate_http_base_url(_base_url),
    do: {:error, {:invalid_transport_options, :base_url}}

  defp validate_http_uri(%URI{
         scheme: scheme,
         host: host,
         userinfo: nil,
         query: nil,
         fragment: nil,
         path: path
       })
       when scheme in ["http", "https"] and is_binary(host) and host != "" and
              path in [nil, "", "/"],
       do: :ok

  defp validate_http_uri(_uri),
    do: {:error, {:invalid_transport_options, :base_url}}

  defp validate_mcp_path("/" <> _rest = path) do
    cond do
      String.starts_with?(path, "//") ->
        {:error, {:invalid_transport_options, :mcp_path}}

      String.contains?(path, "?") ->
        {:error, {:unsupported_transport_option, :mcp_path_query}}

      String.contains?(path, ["#", <<0>>]) ->
        {:error, {:invalid_transport_options, :mcp_path}}

      true ->
        :ok
    end
  end

  defp validate_mcp_path(_path), do: {:error, {:invalid_transport_options, :mcp_path}}

  defp validate_headers(headers) when is_list(headers) do
    normalized_names =
      Enum.map(headers, fn
        {name, _value} when is_binary(name) -> String.downcase(name)
        _header -> nil
      end)

    if Enum.all?(headers, &valid_header?/1) and
         length(normalized_names) == length(Enum.uniq(normalized_names)),
       do: :ok,
       else: {:error, {:invalid_transport_options, :headers}}
  end

  defp validate_headers(_headers), do: {:error, {:invalid_transport_options, :headers}}

  defp valid_header?({name, value}) when is_binary(name) and is_binary(value) do
    byte_size(name) in 1..256 and byte_size(value) <= 8_192 and
      String.match?(name, ~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/) and
      not String.contains?(value, ["\r", "\n", <<0>>])
  end

  defp valid_header?(_header), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
