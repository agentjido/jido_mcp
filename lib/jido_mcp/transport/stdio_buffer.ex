defmodule Jido.MCP.Transport.STDIOBuffer do
  @moduledoc false

  @spec push(binary(), binary()) :: {[binary()], binary()}
  def push(buffer, data) when is_binary(buffer) and is_binary(data) do
    combined = buffer <> data
    {lines, next_buffer} = split_complete_lines(combined)

    messages =
      lines
      |> Enum.flat_map(&normalize_line/1)

    {trailing_messages, next_buffer} = normalize_trailing_buffer(next_buffer)

    {messages ++ trailing_messages, next_buffer}
  end

  defp split_complete_lines(data) do
    parts = String.split(data, "\n", trim: false)

    if String.ends_with?(data, "\n") do
      {Enum.drop(parts, -1), ""}
    else
      {Enum.drop(parts, -1), List.last(parts) || ""}
    end
  end

  defp normalize_line(line) do
    line = String.trim(line)

    cond do
      line == "" ->
        []

      String.starts_with?(line, "{") ->
        normalize_object_line(line)

      String.starts_with?(line, "[") ->
        normalize_batch_line(line)

      true ->
        []
    end
  end

  defp normalize_object_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = message} -> normalize_message(message)
      _ -> []
    end
  end

  defp normalize_batch_line(line) do
    case Jason.decode(line) do
      {:ok, messages} when is_list(messages) ->
        messages
        |> Enum.filter(&is_map/1)
        |> Enum.flat_map(&normalize_message/1)

      _ ->
        []
    end
  end

  defp normalize_trailing_buffer(""), do: {[], ""}

  defp normalize_trailing_buffer(buffer) do
    normalized = String.trim(buffer)

    if json_start?(normalized) do
      case normalize_line(normalized) do
        [] -> {[], buffer}
        messages -> {messages, ""}
      end
    else
      {[], ""}
    end
  end

  defp normalize_message(%{"jsonrpc" => "2.0"} = message), do: [Jason.encode!(message) <> "\n"]
  defp normalize_message(_message), do: []

  defp json_start?(<<"{", _::binary>>), do: true
  defp json_start?(<<"[", _::binary>>), do: true
  defp json_start?(_), do: false
end
