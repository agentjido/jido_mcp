defmodule Jido.MCP.Actions.Helpers do
  @moduledoc false

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
         :ok <- validate_allowed(endpoint_id, context) do
      {:ok, endpoint_id}
    end
  end

  @spec normalize_endpoint_id(term()) ::
          {:ok, atom()} | {:error, :endpoint_required | :invalid_endpoint_id}
  def normalize_endpoint_id(nil), do: {:error, :endpoint_required}
  def normalize_endpoint_id(id) when is_atom(id), do: {:ok, id}
  def normalize_endpoint_id(id) when is_binary(id) and id != "", do: {:ok, String.to_atom(id)}
  def normalize_endpoint_id(_), do: {:error, :invalid_endpoint_id}

  defp validate_allowed(endpoint_id, context) do
    allowed =
      first_present([
        context[:allowed_endpoints],
        get_in(context, [:plugin_state, :mcp, :allowed_endpoints]),
        get_in(context, [:state, :mcp, :allowed_endpoints]),
        get_in(context, [:agent, :state, :mcp, :allowed_endpoints])
      ])

    case allowed do
      nil ->
        :ok

      list when is_list(list) ->
        if endpoint_id in list, do: :ok, else: {:error, :endpoint_not_allowed}

      _ ->
        :ok
    end
  end

  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))
end
