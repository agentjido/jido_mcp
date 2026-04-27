defmodule Jido.MCP.Transport.STDIOBuffer do
  @moduledoc false

  @spec push(binary(), binary()) :: {[binary()], binary()}
  def push(buffer, data) when is_binary(buffer) and is_binary(data) do
    combined = buffer <> data
    {lines, next_buffer} = split_complete_lines(combined)

    messages =
      lines
      |> Enum.flat_map(&normalize_line/1)

    {messages, next_buffer}
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
      {:ok, %{} = message} -> [Jason.encode!(message)]
      _ -> []
    end
  end

  defp normalize_batch_line(line) do
    case Jason.decode(line) do
      {:ok, messages} when is_list(messages) ->
        messages
        |> Enum.filter(&is_map/1)
        |> Enum.map(&Jason.encode!/1)

      _ ->
        []
    end
  end
end
