defmodule Jido.MCP.Endpoint do
  @moduledoc """
  Runtime endpoint definition for an MCP server connection.
  """

  @default_protocol_version "2025-06-18"
  @legacy_sse_protocol_version "2024-11-05"
  @default_request_timeout_ms 30_000

  @type id :: atom()
  @type transport :: {:stdio, keyword()} | {:sse, keyword()} | {:streamable_http, keyword()}

  @type t :: %__MODULE__{
          id: id(),
          transport: transport(),
          client_info: %{required(String.t()) => String.t()},
          protocol_version: String.t(),
          capabilities: map(),
          timeouts: %{request_ms: pos_integer()}
        }

  @enforce_keys [:id, :transport, :client_info, :protocol_version, :capabilities, :timeouts]
  defstruct [:id, :transport, :client_info, :protocol_version, :capabilities, :timeouts]

  @spec new(id(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(id, attrs) when is_atom(id) and is_list(attrs) do
    new(id, Enum.into(attrs, %{}))
  end

  def new(id, attrs) when is_atom(id) and is_map(attrs) do
    with {:ok, transport} <-
           validate_transport(Map.get(attrs, :transport, Map.get(attrs, "transport"))),
         {:ok, client_info} <-
           validate_client_info(Map.get(attrs, :client_info, Map.get(attrs, "client_info"))),
         {:ok, protocol_version} <-
           validate_protocol(
             transport,
             Map.get(attrs, :protocol_version, Map.get(attrs, "protocol_version"))
           ),
         {:ok, capabilities} <-
           validate_capabilities(
             Map.get(attrs, :capabilities, Map.get(attrs, "capabilities", %{}))
           ),
         {:ok, timeouts} <-
           validate_timeouts(Map.get(attrs, :timeouts, Map.get(attrs, "timeouts", %{}))) do
      {:ok,
       %__MODULE__{
         id: id,
         transport: transport,
         client_info: client_info,
         protocol_version: protocol_version,
         capabilities: capabilities,
         timeouts: timeouts
       }}
    end
  end

  defp validate_transport({:stdio, opts}) when is_list(opts),
    do: validate_transport_opts(:stdio, opts)

  defp validate_transport({:shell, opts}) when is_list(opts),
    do: validate_transport_opts(:stdio, opts)

  defp validate_transport({:sse, opts}) when is_list(opts),
    do: validate_transport_opts(:sse, opts)

  defp validate_transport({:streamable_http, opts}) when is_list(opts),
    do: validate_transport_opts(:streamable_http, opts)

  defp validate_transport(other),
    do:
      {:error,
       {:invalid_transport, other,
        "transport must be {:stdio, keyword()}, {:shell, keyword()}, {:sse, keyword()}, or {:streamable_http, keyword()}"}}

  defp validate_transport_opts(_layer, opts) when not is_list(opts) do
    {:error, {:invalid_transport_options, opts, "transport options must be a keyword list"}}
  end

  defp validate_transport_opts(layer, opts) do
    if Keyword.keyword?(opts) do
      {:ok, {layer, normalize_transport_opts(layer, opts)}}
    else
      {:error, {:invalid_transport_options, opts, "transport options must be a keyword list"}}
    end
  end

  defp normalize_transport_opts(:streamable_http, opts) do
    opts
    |> normalize_streamable_http_url()
    |> normalize_streamable_http_base_url()
  end

  defp normalize_transport_opts(:sse, opts) do
    if Keyword.has_key?(opts, :server) do
      opts
    else
      {server_opts, transport_opts} = Keyword.split(opts, [:base_url, :base_path, :sse_path])

      if server_opts == [] do
        opts
      else
        Keyword.put(transport_opts, :server, server_opts)
      end
    end
  end

  defp normalize_transport_opts(_layer, opts), do: opts

  defp normalize_streamable_http_url(opts) do
    case Keyword.pop(opts, :url) do
      {nil, opts} -> opts
      {url, opts} when is_binary(url) -> put_url_parts(opts, url)
      {url, opts} -> Keyword.put(opts, :url, url)
    end
  end

  defp normalize_streamable_http_base_url(opts) do
    base_url = Keyword.get(opts, :base_url)

    if is_binary(base_url) and not Keyword.has_key?(opts, :mcp_path) and pathful_url?(base_url) do
      put_url_parts(Keyword.delete(opts, :base_url), base_url)
    else
      opts
    end
  end

  defp put_url_parts(opts, url) do
    uri = URI.parse(url)
    path = endpoint_path(uri)

    opts
    |> Keyword.put(:base_url, base_uri(uri))
    |> Keyword.put(:mcp_path, path)
  end

  defp pathful_url?(url) do
    case URI.parse(url).path do
      path when is_binary(path) and path not in ["", "/"] -> true
      _ -> false
    end
  end

  defp endpoint_path(%URI{} = uri) do
    path = if is_binary(uri.path) and uri.path != "", do: uri.path, else: "/mcp"

    if is_binary(uri.query) and uri.query != "" do
      path <> "?" <> uri.query
    else
      path
    end
  end

  defp base_uri(%URI{} = uri) do
    uri
    |> Map.put(:path, nil)
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp validate_client_info(%{"name" => name} = info) when is_binary(name) do
    version = Map.get(info, "version", "1.0.0")
    {:ok, %{"name" => name, "version" => to_string(version)}}
  end

  defp validate_client_info(%{name: name} = info) when is_binary(name) do
    version = Map.get(info, :version, "1.0.0")
    {:ok, %{"name" => name, "version" => to_string(version)}}
  end

  defp validate_client_info(other),
    do: {:error, {:invalid_client_info, other, "client_info must include a string name"}}

  defp validate_protocol({:sse, _opts}, nil), do: {:ok, @legacy_sse_protocol_version}
  defp validate_protocol(_transport, nil), do: {:ok, @default_protocol_version}

  defp validate_protocol(_transport, version) when is_binary(version) and version != "",
    do: {:ok, version}

  defp validate_protocol(_transport, other),
    do:
      {:error, {:invalid_protocol_version, other, "protocol_version must be a non-empty string"}}

  defp validate_capabilities(cap) when is_map(cap), do: {:ok, cap}
  defp validate_capabilities(nil), do: {:ok, %{}}

  defp validate_capabilities(other),
    do: {:error, {:invalid_capabilities, other, "capabilities must be a map"}}

  defp validate_timeouts(%{} = timeouts) do
    request_ms =
      Map.get(timeouts, :request_ms, Map.get(timeouts, "request_ms", @default_request_timeout_ms))

    if is_integer(request_ms) and request_ms > 0 do
      {:ok, %{request_ms: request_ms}}
    else
      {:error, {:invalid_timeouts, timeouts, "timeouts.request_ms must be a positive integer"}}
    end
  end

  defp validate_timeouts(nil), do: {:ok, %{request_ms: @default_request_timeout_ms}}

  defp validate_timeouts(other),
    do: {:error, {:invalid_timeouts, other, "timeouts must be a map"}}
end
