defmodule Jido.MCP.Endpoint do
  @moduledoc """
  Runtime endpoint definition for an MCP server connection.
  """

  @default_protocol_version "2025-03-26"
  @default_request_timeout_ms 30_000

  @type id :: atom()
  @type transport :: {:stdio, keyword()} | {:streamable_http, keyword()}

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

  defp validate_transport({:stdio, opts}) when is_list(opts), do: {:ok, {:stdio, opts}}

  defp validate_transport({:streamable_http, opts}) when is_list(opts),
    do: {:ok, {:streamable_http, opts}}

  defp validate_transport(other),
    do:
      {:error,
       {:invalid_transport, other,
        "transport must be {:stdio, keyword()} or {:streamable_http, keyword()}"}}

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

  defp validate_protocol(nil), do: {:ok, @default_protocol_version}
  defp validate_protocol(version) when is_binary(version) and version != "", do: {:ok, version}

  defp validate_protocol(other),
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
