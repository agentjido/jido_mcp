defmodule Jido.MCP.Actions.Helpers do
  @moduledoc false

  alias Jido.MCP.{ClientPool, EndpointID}

  @spec resolve_endpoint_id(map(), map()) :: {:ok, atom()} | {:error, term()}
  def resolve_endpoint_id(params, context) do
    endpoint_id =
      first_present([
        params[:endpoint_id],
        params["endpoint_id"],
        context[:endpoint_id],
        context["endpoint_id"],
        context[:default_endpoint],
        get_in(context, [:plugin_state, :mcp, :default_endpoint]),
        get_in(context, [:state, :mcp, :default_endpoint]),
        get_in(context, [:agent, :state, :mcp, :default_endpoint])
      ])

    with {:ok, endpoint_id} <- normalize_endpoint_id(endpoint_id),
         :ok <- validate_allowed_endpoint(endpoint_id, context) do
      {:ok, endpoint_id}
    end
  end

  @spec normalize_endpoint_id(term()) ::
          {:ok, atom()} | {:error, :endpoint_required | :invalid_endpoint_id | :unknown_endpoint}
  def normalize_endpoint_id(id), do: ClientPool.resolve_endpoint_id(id)

  @spec validate_allowed_endpoint(atom(), map()) :: :ok | {:error, term()}
  def validate_allowed_endpoint(endpoint_id, context) do
    allowed =
      first_present([
        context[:allowed_endpoints],
        context["allowed_endpoints"],
        get_in(context, [:plugin_state, :mcp, :allowed_endpoints]),
        get_in(context, [:state, :mcp, :allowed_endpoints]),
        get_in(context, [:agent, :state, :mcp, :allowed_endpoints])
      ])

    case normalize_allowed_endpoints(allowed) do
      nil ->
        :ok

      {:ok, :all} ->
        :ok

      {:ok, list} ->
        if endpoint_id in list, do: :ok, else: {:error, :endpoint_not_allowed}

      _ ->
        {:error, :invalid_allowed_endpoints}
    end
  end

  defp normalize_allowed_endpoints(nil), do: nil
  defp normalize_allowed_endpoints(:all), do: {:ok, :all}

  defp normalize_allowed_endpoints(values) when is_list(values) do
    endpoints = ClientPool.endpoints()

    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case EndpointID.resolve(value, endpoints) do
        {:ok, endpoint_id} -> {:cont, {:ok, [endpoint_id | acc]}}
        {:error, _reason} -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, endpoint_ids} -> {:ok, Enum.reverse(endpoint_ids)}
      :error -> :error
    end
  end

  defp normalize_allowed_endpoints(_), do: :error

  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))
end
