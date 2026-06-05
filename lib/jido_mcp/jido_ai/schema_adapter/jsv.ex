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
  @default_max_depth 8
  @default_max_properties 200

  @schema_child_keys ~w(
    additionalProperties
    contains
    if
    then
    else
    not
    propertyNames
    items
  )

  @schema_map_child_keys ~w(
    $defs
    definitions
    dependentSchemas
    patternProperties
    properties
  )

  @schema_list_child_keys ~w(
    allOf
    anyOf
    oneOf
    prefixItems
  )

  @impl true
  def compile(nil, opts) do
    compile(%{"type" => "object", "properties" => %{}}, opts)
  end

  def compile(schema, opts) when is_map(schema) do
    max_depth = normalize_limit(Keyword.get(opts, :max_depth), @default_max_depth)
    max_properties = normalize_limit(Keyword.get(opts, :max_properties), @default_max_properties)

    schema =
      schema
      |> stringify_keys()
      |> Map.put_new("$schema", @default_schema)

    with :ok <- enforce_schema_limits(schema, max_depth, max_properties) do
      case JSV.build(schema, atoms: false, warnings: :silent) do
        {:ok, root} ->
          {:ok, root}

        {:error, error} ->
          {:error, normalize_error(:invalid_schema, error)}
      end
    end
  end

  def compile(_schema, _opts) do
    {:error, %{code: :invalid_schema, message: "tool input schema must be a map", path: []}}
  end

  @impl true
  def validate(root, params) when is_map(params) and not is_struct(params) do
    case JSV.validate(params, root, cast: false) do
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

  defp normalize_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_limit(_value, default), do: default

  defp enforce_schema_limits(schema, max_depth, max_properties) do
    case inspect_schema(schema, [], 1, 0, max_depth, max_properties) do
      {:ok, _property_count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp inspect_schema(_schema, path, depth, _property_count, max_depth, _max_properties)
       when depth > max_depth do
    {:error, error(:schema_too_deep, "tool schema depth exceeds #{max_depth}", path)}
  end

  defp inspect_schema(schema, path, depth, property_count, max_depth, max_properties)
       when is_map(schema) do
    with {:ok, property_count} <- count_properties(schema, path, property_count, max_properties) do
      schema
      |> schema_children()
      |> Enum.reduce_while({:ok, property_count}, fn {child_path, child_schema},
                                                     {:ok, current_count} ->
        case inspect_schema(
               child_schema,
               path ++ child_path,
               depth + 1,
               current_count,
               max_depth,
               max_properties
             ) do
          {:ok, next_count} -> {:cont, {:ok, next_count}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp inspect_schema(_schema, _path, _depth, property_count, _max_depth, _max_properties) do
    {:ok, property_count}
  end

  defp count_properties(schema, path, property_count, max_properties) do
    properties = Map.get(schema, "properties")

    next_count =
      if is_map(properties) do
        property_count + map_size(properties)
      else
        property_count
      end

    if next_count > max_properties do
      {:error, error(:schema_too_large, "tool schema properties exceed #{max_properties}", path)}
    else
      {:ok, next_count}
    end
  end

  defp schema_children(schema) do
    direct_children =
      for key <- @schema_child_keys,
          child = Map.get(schema, key),
          is_map(child) do
        {[key], child}
      end

    map_children =
      for key <- @schema_map_child_keys,
          children = Map.get(schema, key),
          is_map(children),
          {child_key, child_schema} <- children,
          is_map(child_schema) do
        {[key, child_key], child_schema}
      end

    list_children =
      for key <- @schema_list_child_keys,
          children = Map.get(schema, key),
          is_list(children),
          {child_schema, index} <- Enum.with_index(children),
          is_map(child_schema) do
        {[key, index], child_schema}
      end

    direct_children ++ map_children ++ list_children
  end

  defp error(code, message, path) do
    %{code: code, message: message, path: path}
  end

  defp normalize_error(code, error) do
    %{
      code: code,
      message: inspect(error),
      path: []
    }
  end
end
