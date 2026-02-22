defmodule Jido.MCP.Config do
  @moduledoc """
  Loads and validates application MCP endpoint configuration.
  """

  alias Jido.MCP.Endpoint

  @type endpoints :: %{required(atom()) => Endpoint.t()}

  @spec endpoints() :: endpoints()
  def endpoints do
    :jido_mcp
    |> Application.get_env(:endpoints, %{})
    |> normalize_endpoints()
  end

  @spec fetch_endpoint(atom()) :: {:ok, Endpoint.t()} | {:error, :unknown_endpoint}
  def fetch_endpoint(endpoint_id) when is_atom(endpoint_id) do
    case Map.fetch(endpoints(), endpoint_id) do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> {:error, :unknown_endpoint}
    end
  end

  @spec normalize_endpoints(map() | keyword()) :: endpoints()
  def normalize_endpoints(endpoints) when is_list(endpoints) do
    endpoints
    |> Enum.into(%{})
    |> normalize_endpoints()
  end

  def normalize_endpoints(endpoints) when is_map(endpoints) do
    Enum.reduce(endpoints, %{}, fn {id, attrs}, acc ->
      id = normalize_id(id)

      case Endpoint.new(id, attrs) do
        {:ok, endpoint} ->
          Map.put(acc, id, endpoint)

        {:error, reason} ->
          raise ArgumentError, "Invalid endpoint #{inspect(id)}: #{inspect(reason)}"
      end
    end)
  end

  def normalize_endpoints(_), do: %{}

  defp normalize_id(id) when is_atom(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_atom(id)
end
