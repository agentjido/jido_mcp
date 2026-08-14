defmodule Jido.MCP.Response do
  @moduledoc """
  Helpers for normalizing ExMCP responses into stable Jido.MCP result contracts.
  """

  @type ok_result :: %{
          status: :ok,
          endpoint: Jido.MCP.Endpoint.id(),
          method: String.t(),
          data: map(),
          raw: map()
        }

  @type error_result :: %{
          status: :error,
          endpoint: Jido.MCP.Endpoint.id(),
          method: String.t(),
          type: :transport | :protocol | :tool_error | :validation,
          message: String.t(),
          details: term()
        }

  @spec normalize(
          Jido.MCP.Endpoint.id(),
          String.t(),
          {:ok, map()} | {:error, term()}
        ) ::
          {:ok, ok_result()} | {:error, error_result()}
  def normalize(endpoint_id, method, {:ok, response}) when is_map(response) do
    if tool_error?(response) do
      {:error,
       %{
         status: :error,
         endpoint: endpoint_id,
         method: method,
         type: :tool_error,
         message: extract_error_message(response),
         details: response
       }}
    else
      {:ok,
       %{
         status: :ok,
         endpoint: endpoint_id,
         method: method,
         data: response,
         raw: response
       }}
    end
  end

  def normalize(endpoint_id, method, {:error, reason}) do
    {:error,
     %{
       status: :error,
       endpoint: endpoint_id,
       method: method,
       type: classify_error(reason),
       message: extract_error_message(reason),
       details: reason
     }}
  end

  def normalize(endpoint_id, method, _invalid_response) do
    {:error,
     %{
       status: :error,
       endpoint: endpoint_id,
       method: method,
       type: :transport,
       message: "The MCP client returned an invalid response",
       details: :invalid_client_response
     }}
  end

  defp classify_error(%{reason: reason}), do: classify_reason(reason)
  defp classify_error({:error, reason}), do: classify_error(reason)
  defp classify_error(reason) when is_atom(reason), do: classify_reason(reason)
  defp classify_error(_), do: :transport

  defp classify_reason(reason) when reason in [:parse_error, :invalid_params], do: :validation

  defp classify_reason(:tool_error), do: :tool_error

  defp classify_reason(reason)
       when reason in [:invalid_request, :method_not_found, :internal_error, :protocol_error],
       do: :protocol

  defp classify_reason(_), do: :transport

  defp extract_error_message(%{"message" => message}) when is_binary(message), do: message
  defp extract_error_message(%{message: message}) when is_binary(message), do: message

  defp extract_error_message(%{"error" => message}) when is_binary(message),
    do: message

  defp extract_error_message(%{error: message}) when is_binary(message),
    do: message

  defp extract_error_message(%{"isError" => true}), do: "The MCP tool returned an error"
  defp extract_error_message(%{isError: true}), do: "The MCP tool returned an error"

  defp extract_error_message(%{} = data), do: inspect(data)
  defp extract_error_message(data), do: inspect(data)

  defp tool_error?(%{"isError" => true}), do: true
  defp tool_error?(%{isError: true}), do: true
  defp tool_error?(_response), do: false
end
