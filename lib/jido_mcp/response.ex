defmodule Jido.MCP.Response do
  @moduledoc """
  Helpers for normalizing Anubis responses into stable Jido.MCP result contracts.
  """

  alias Anubis.MCP.Response, as: MCPResponse

  @type ok_result :: %{
          status: :ok,
          endpoint: atom(),
          method: String.t(),
          data: map(),
          raw: MCPResponse.t()
        }

  @type error_result :: %{
          status: :error,
          endpoint: atom(),
          type: :transport | :protocol | :tool_error | :validation,
          message: String.t(),
          details: term()
        }

  @spec normalize(atom(), String.t(), {:ok, MCPResponse.t()} | {:error, term()}) ::
          {:ok, ok_result()} | {:error, error_result()}
  def normalize(endpoint_id, method, {:ok, %MCPResponse{} = response}) do
    data = MCPResponse.unwrap(response)

    if MCPResponse.error?(response) do
      {:error,
       %{
         status: :error,
         endpoint: endpoint_id,
         type: :tool_error,
         message: extract_error_message(data),
         details: data
       }}
    else
      {:ok,
       %{
         status: :ok,
         endpoint: endpoint_id,
         method: method,
         data: data,
         raw: response
       }}
    end
  end

  def normalize(endpoint_id, _method, {:error, reason}) do
    {:error,
     %{
       status: :error,
       endpoint: endpoint_id,
       type: classify_error(reason),
       message: extract_error_message(reason),
       details: reason
     }}
  end

  defp classify_error(%{reason: :parse_error}), do: :validation
  defp classify_error(%{reason: :invalid_params}), do: :validation
  defp classify_error(%{reason: :invalid_request}), do: :protocol
  defp classify_error(%{reason: :method_not_found}), do: :protocol
  defp classify_error(%{reason: :internal_error}), do: :protocol
  defp classify_error(%{reason: _}), do: :transport
  defp classify_error(_), do: :transport

  defp extract_error_message(%{"message" => message}) when is_binary(message), do: message
  defp extract_error_message(%{message: message}) when is_binary(message), do: message

  defp extract_error_message(%{"error" => message}) when is_binary(message),
    do: message

  defp extract_error_message(%{error: message}) when is_binary(message),
    do: message

  defp extract_error_message(%{} = data), do: inspect(data)
  defp extract_error_message(data), do: inspect(data)
end
