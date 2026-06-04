defmodule Jido.MCP.JidoAI.SchemaAdapter.JSV do
  @moduledoc """
  Full JSON Schema adapter using the `jsv` package (Draft 2020-12 compliant).

  This is the recommended default for Jido MCP JidoAI proxies because MCP
  tool inputSchemas are JSON Schema (default 2020-12) and real servers use
  advanced constructs that the old strict validator rejects (e.g. $ref, oneOf,
  format, patternProperties, $schema at root, etc.).

  See issues #21, #23, #24.
  """

  @behaviour Jido.MCP.JidoAI.SchemaAdapter

  @default_schema "https://json-schema.org/draft/2020-12/schema"

  @impl true
  def compile(nil, _opts) do
    compile(%{"type" => "object", "properties" => %{}}, [])
  end

  def compile(schema, _opts) when is_map(schema) do
    schema =
      schema
      |> stringify_keys()
      |> Map.put_new("$schema", @default_schema)

    case JSV.build(schema) do
      {:ok, root} ->
        {:ok, root}

      {:error, error} ->
        {:error, normalize_error(:invalid_schema, error)}
    end
  end

  def compile(_schema, _opts) do
    {:error, %{code: :invalid_schema, message: "tool input schema must be a map", path: []}}
  end

  @impl true
  def validate(root, params) when is_map(params) and not is_struct(params) do
    case JSV.validate(params, root) do
      {:ok, _validated} -> :ok
      {:error, error} -> {:error, normalize_error(:invalid_arguments, error)}
    end
  end

  def validate(_root, _params) do
    {:error, %{code: :invalid_arguments, message: "tool arguments must be a map", path: []}}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} when is_binary(key) -> {key, stringify_keys(value)}
      {key, value} -> {to_string(key), stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp normalize_error(code, error) do
    %{
      code: code,
      message: inspect(error),
      path: []
    }
  end
end
