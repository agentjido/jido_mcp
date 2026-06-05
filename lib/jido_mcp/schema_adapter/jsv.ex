defmodule Jido.MCP.SchemaAdapter.JSV do
  @moduledoc false

  @behaviour Jido.MCP.SchemaAdapter

  @default_schema "https://json-schema.org/draft/2020-12/schema"
  @default_max_depth 8
  @default_max_properties 200

  @impl true
  def compile(nil, opts) do
    compile(%{"type" => "object", "properties" => %{}}, opts)
  end

  def compile(schema, opts) when is_map(schema) and not is_struct(schema) do
    schema = stringify_keys(schema)

    max_depth =
      normalize_limit(Keyword.get(opts, :max_depth, @default_max_depth), @default_max_depth)

    max_properties =
      normalize_limit(
        Keyword.get(opts, :max_properties, @default_max_properties),
        @default_max_properties
      )

    with :ok <- validate_schema_shape(schema, max_depth, max_properties),
         :ok <- validate_root_object(schema) do
      schema
      |> Map.put_new("$schema", @default_schema)
      |> JSV.build()
      |> case do
        {:ok, root} -> {:ok, root}
        {:error, error} -> {:error, normalize_error(:invalid_schema, error)}
      end
    end
  end

  def compile(_schema, _opts) do
    {:error, error(:invalid_schema, "tool input schema must be a map or nil", [])}
  end

  @impl true
  def validate(root, params) when is_map(params) and not is_struct(params) do
    params = stringify_keys(params)

    case JSV.validate(params, root) do
      {:ok, _validated} -> {:ok, params}
      {:error, error} -> {:error, normalize_error(:invalid_arguments, error)}
    end
  end

  def validate(_root, _params) do
    {:error, error(:invalid_arguments, "tool arguments must be a map", [])}
  end

  defp validate_root_object(schema) do
    case Map.get(schema, "type") do
      "object" ->
        :ok

      nil ->
        {:error, error(:invalid_schema, "tool input schema must declare type object", [])}

      other ->
        {:error,
         error(
           :invalid_schema,
           "tool input schema type must be object, got #{inspect(other)}",
           []
         )}
    end
  end

  defp validate_schema_shape(schema, max_depth, max_properties) do
    schema
    |> walk_schema([], 1, %{depth: 1, properties: 0}, max_depth, max_properties)
    |> case do
      {:ok, _stats} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk_schema(value, path, depth, stats, max_depth, max_properties) when is_map(value) do
    cond do
      depth > max_depth ->
        {:error, error(:schema_too_deep, "tool schema depth exceeds #{max_depth}", path)}

      true ->
        stats = %{stats | depth: max(stats.depth, depth)}

        value
        |> Enum.reduce_while({:ok, stats}, fn
          {"properties", properties}, {:ok, cur_stats} when is_map(properties) ->
            property_count = map_size(properties)
            next_stats = %{cur_stats | properties: cur_stats.properties + property_count}

            if next_stats.properties > max_properties do
              {:halt,
               {:error,
                error(
                  :schema_too_large,
                  "tool schema properties exceed #{max_properties}",
                  path ++ ["properties"]
                )}}
            else
              case walk_schema_map(
                     properties,
                     path ++ ["properties"],
                     depth + 1,
                     next_stats,
                     max_depth,
                     max_properties
                   ) do
                {:ok, final_stats} -> {:cont, {:ok, final_stats}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end

          {key, child}, {:ok, cur_stats} ->
            if schema_container_key?(key) do
              case walk_schema(
                     child,
                     path ++ [key],
                     depth + 1,
                     cur_stats,
                     max_depth,
                     max_properties
                   ) do
                {:ok, next_stats} -> {:cont, {:ok, next_stats}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            else
              {:cont, {:ok, cur_stats}}
            end
        end)
    end
  end

  defp walk_schema(list, path, depth, stats, max_depth, max_properties) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, stats}, fn {child, index}, {:ok, cur_stats} ->
      case walk_schema(child, path ++ [index], depth + 1, cur_stats, max_depth, max_properties) do
        {:ok, next_stats} -> {:cont, {:ok, next_stats}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp walk_schema(_value, _path, _depth, stats, _max_depth, _max_properties), do: {:ok, stats}

  defp walk_schema_map(map, path, depth, stats, max_depth, max_properties) do
    map
    |> Enum.reduce_while({:ok, stats}, fn {key, child}, {:ok, cur_stats} ->
      case walk_schema(child, path ++ [key], depth, cur_stats, max_depth, max_properties) do
        {:ok, next_stats} -> {:cont, {:ok, next_stats}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp schema_container_key?(key) do
    key in ~w(
      additionalItems additionalProperties allOf anyOf contains dependentSchemas
      else if items not oneOf patternProperties prefixItems propertyNames then
      unevaluatedItems unevaluatedProperties $defs definitions
    )
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

  defp normalize_limit(value, _fallback) when is_integer(value) and value > 0, do: value
  defp normalize_limit(_value, fallback), do: fallback

  defp normalize_error(code, %JSV.ValidationError{} = error) do
    first_error =
      Enum.find(error.errors, fn
        %JSV.Validator.Error{data_path: [_ | _]} -> true
        _error -> false
      end) || List.first(error.errors)

    error(
      code,
      inspect(error),
      validation_error_path(first_error)
    )
  end

  defp normalize_error(code, error), do: error(code, inspect(error), [])

  defp validation_error_path(%JSV.Validator.Error{data_path: path}) when is_list(path), do: path
  defp validation_error_path(_error), do: []

  defp error(code, message, path), do: %{code: code, message: message, path: path}
end
