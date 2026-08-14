defmodule Jido.MCP.EndpointID do
  @moduledoc false

  alias Jido.MCP.Config

  @type endpoint_id :: atom() | String.t()
  @type resolve_error :: :endpoint_required | :invalid_endpoint_id | :unknown_endpoint
  @max_endpoint_id_bytes 255

  @spec equivalent?(term(), term()) :: boolean()
  def equivalent?(left, right)
      when (is_atom(left) or is_binary(left)) and (is_atom(right) or is_binary(right)) do
    endpoint_string(left) == endpoint_string(right)
  end

  def equivalent?(_left, _right), do: false

  @spec resolve(term()) :: {:ok, endpoint_id()} | {:error, resolve_error()}
  def resolve(value), do: resolve(value, Config.endpoints())

  @spec resolve(term(), map()) :: {:ok, endpoint_id()} | {:error, resolve_error()}
  def resolve(nil, _endpoints), do: {:error, :endpoint_required}

  def resolve(endpoint_id, endpoints) when is_atom(endpoint_id) and is_map(endpoints) do
    cond do
      Map.has_key?(endpoints, endpoint_id) ->
        {:ok, endpoint_id}

      resolved_id = Enum.find(Map.keys(endpoints), &equivalent?(&1, endpoint_id)) ->
        {:ok, resolved_id}

      true ->
        {:error, :unknown_endpoint}
    end
  end

  def resolve(endpoint_id, endpoints) when is_binary(endpoint_id) and is_map(endpoints) do
    endpoint_id = if String.valid?(endpoint_id), do: String.trim(endpoint_id), else: endpoint_id

    cond do
      not valid_lookup_id?(endpoint_id) ->
        {:error, :invalid_endpoint_id}

      Map.has_key?(endpoints, endpoint_id) ->
        {:ok, endpoint_id}

      true ->
        case Enum.find(Map.keys(endpoints), &(endpoint_string(&1) == endpoint_id)) do
          nil -> {:error, :unknown_endpoint}
          id -> {:ok, id}
        end
    end
  end

  def resolve(_endpoint_id, _endpoints), do: {:error, :invalid_endpoint_id}

  defp endpoint_string(id) when is_atom(id), do: Atom.to_string(id)
  defp endpoint_string(id) when is_binary(id), do: id
  defp endpoint_string(_id), do: nil

  defp valid_lookup_id?(id) do
    String.valid?(id) and byte_size(id) in 1..@max_endpoint_id_bytes and
      not String.match?(id, ~r/[\x00-\x1F\x7F]/u)
  end
end
