defmodule Jido.MCP.SchemaAdapter.StrictSubset do
  @moduledoc false

  @behaviour Jido.MCP.SchemaAdapter

  @type compiled_schema :: map()
  @type validation_error :: %{code: atom(), message: String.t(), path: [term()]}

  @unsupported_constructs ~w(
    $ref oneOf allOf not if then else
    patternProperties dependentSchemas dependencies
    unevaluatedProperties unevaluatedItems prefixItems contains
  )

  @common_schema_keys ~w(type description title default examples)
  @any_of_schema_keys ~w(anyOf description title default examples)
  @object_schema_keys @common_schema_keys ++ ~w(properties required additionalProperties)
  @array_schema_keys @common_schema_keys ++ ~w(items minItems maxItems)
  @string_schema_keys @common_schema_keys ++ ~w(enum minLength maxLength)
  @integer_schema_keys @common_schema_keys ++ ~w(enum minimum maximum)
  @number_schema_keys @common_schema_keys ++ ~w(enum minimum maximum)
  @boolean_schema_keys @common_schema_keys ++ ~w(enum)
  @null_schema_keys @common_schema_keys

  @default_max_depth 8
  @default_max_properties 200

  @spec compile(map() | nil, keyword()) :: {:ok, compiled_schema()} | {:error, validation_error()}
  def compile(schema, opts \\ []) do
    max_depth =
      normalize_limit(Keyword.get(opts, :max_depth, @default_max_depth), @default_max_depth)

    max_properties =
      normalize_limit(
        Keyword.get(opts, :max_properties, @default_max_properties),
        @default_max_properties
      )

    with {:ok, normalized} <- normalize_root_schema(schema),
         {:ok, compiled, _stats} <-
           compile_schema(
             normalized,
             [],
             1,
             %{depth: 1, properties: 0},
             max_depth,
             max_properties
           ) do
      {:ok, compiled}
    end
  end

  @spec validate(compiled_schema(), map()) :: :ok | {:error, validation_error()}
  def validate(compiled_schema, params) when is_map(params) and not is_struct(params) do
    validate_value(compiled_schema, params, [])
  end

  def validate(_compiled_schema, _params) do
    {:error, error(:invalid_arguments, "tool arguments must be a map", [])}
  end

  defp normalize_root_schema(nil),
    do: {:ok, %{"type" => "object", "properties" => %{}, "required" => []}}

  defp normalize_root_schema(schema) when is_map(schema) and not is_struct(schema) do
    {:ok, schema |> stringify_schema_keys() |> Map.delete("$schema")}
  end

  defp normalize_root_schema(_schema) do
    {:error, error(:invalid_schema, "tool input schema must be a map or nil", [])}
  end

  defp compile_schema(schema, path, depth, stats, max_depth, max_properties) do
    schema = stringify_schema_keys(schema)

    cond do
      depth > max_depth ->
        {:error, error(:schema_too_deep, "tool schema depth exceeds #{max_depth}", path)}

      Map.has_key?(schema, "anyOf") ->
        compile_nullable_any_of(schema, path, depth, stats, max_depth, max_properties)

      true ->
        with :ok <- reject_unsupported_constructs(schema, path),
             type <- infer_schema_type(schema),
             :ok <- reject_unknown_keys(schema, type, path) do
          case type do
            "object" ->
              compile_object(schema, path, depth, stats, max_depth, max_properties)

            "array" ->
              compile_array(schema, path, depth, stats, max_depth, max_properties)

            type when type in ["string", "integer", "number", "boolean"] ->
              compile_scalar(schema, type, path, stats)

            _ ->
              {:error,
               error(
                 :unsupported_schema_type,
                 "unsupported schema type #{inspect(Map.get(schema, "type"))}",
                 path
               )}
          end
        end
    end
  end

  defp compile_object(schema, path, depth, stats, max_depth, max_properties) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])
    additional = Map.get(schema, "additionalProperties", false)

    cond do
      not is_map(properties) ->
        {:error, error(:invalid_schema, "object properties must be a map", path)}

      not is_list(required) or Enum.any?(required, &(not is_binary(&1))) ->
        {:error, error(:invalid_schema, "required must be a list of strings", path)}

      additional not in [false, nil] ->
        {:error,
         error(
           :unsupported_schema,
           "additionalProperties must be false or omitted for strict validation",
           path
         )}

      true ->
        required_set = MapSet.new(required)
        property_keys = Map.keys(properties) |> MapSet.new()

        if not MapSet.subset?(required_set, property_keys) do
          {:error, error(:invalid_schema, "required keys must exist in properties", path)}
        else
          Enum.reduce_while(properties, {:ok, %{}, stats}, fn {key, sub_schema},
                                                              {:ok, acc, cur_stats} ->
            cond do
              not is_binary(key) or String.trim(key) == "" ->
                {:halt,
                 {:error,
                  error(:invalid_schema, "property names must be non-empty strings", path)}}

              not is_map(sub_schema) or is_struct(sub_schema) ->
                {:halt,
                 {:error,
                  error(:invalid_schema, "property schema must be an object", path ++ [key])}}

              true ->
                updated_stats = %{
                  cur_stats
                  | depth: max(cur_stats.depth, depth + 1),
                    properties: cur_stats.properties + 1
                }

                if updated_stats.properties > max_properties do
                  {:halt,
                   {:error,
                    error(
                      :schema_too_large,
                      "tool schema properties exceed #{max_properties}",
                      path ++ [key]
                    )}}
                else
                  case compile_schema(
                         sub_schema,
                         path ++ [key],
                         depth + 1,
                         updated_stats,
                         max_depth,
                         max_properties
                       ) do
                    {:ok, compiled, child_stats} ->
                      {:cont, {:ok, Map.put(acc, key, compiled), child_stats}}

                    {:error, reason} ->
                      {:halt, {:error, reason}}
                  end
                end
            end
          end)
          |> case do
            {:ok, compiled_properties, final_stats} ->
              {:ok,
               %{
                 kind: :object,
                 properties: compiled_properties,
                 required: required_set,
                 additional: false
               }, final_stats}

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp compile_array(schema, path, depth, stats, max_depth, max_properties) do
    items = Map.get(schema, "items")

    cond do
      not is_map(items) or is_struct(items) ->
        {:error, error(:invalid_schema, "array items must be an object schema", path)}

      true ->
        with {:ok, min_items} <-
               normalize_non_negative_int(Map.get(schema, "minItems"), "minItems", path),
             {:ok, max_items} <-
               normalize_non_negative_int(Map.get(schema, "maxItems"), "maxItems", path),
             :ok <- validate_item_bounds(min_items, max_items, path),
             {:ok, compiled_items, final_stats} <-
               compile_schema(
                 items,
                 path ++ ["items"],
                 depth + 1,
                 stats,
                 max_depth,
                 max_properties
               ) do
          {:ok,
           %{
             kind: :array,
             items: compiled_items,
             min_items: min_items,
             max_items: max_items
           }, final_stats}
        end
    end
  end

  defp compile_scalar(schema, type, path, stats) do
    with {:ok, enum} <- normalize_enum(Map.get(schema, "enum"), type, path),
         {:ok, min_length} <-
           normalize_non_negative_int(Map.get(schema, "minLength"), "minLength", path),
         {:ok, max_length} <-
           normalize_non_negative_int(Map.get(schema, "maxLength"), "maxLength", path),
         :ok <- validate_item_bounds(min_length, max_length, path),
         {:ok, minimum} <- normalize_number(Map.get(schema, "minimum"), "minimum", path),
         {:ok, maximum} <- normalize_number(Map.get(schema, "maximum"), "maximum", path),
         :ok <- validate_number_bounds(minimum, maximum, path) do
      {:ok,
       %{
         kind: String.to_existing_atom(type),
         enum: enum,
         min_length: min_length,
         max_length: max_length,
         minimum: minimum,
         maximum: maximum
       }, stats}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compile_nullable_any_of(schema, path, depth, stats, max_depth, max_properties) do
    with :ok <- reject_unknown_schema_keys(schema, @any_of_schema_keys, path),
         {:ok, branch, branch_path} <- nullable_any_of_branch(schema, path),
         {:ok, compiled_branch, final_stats} <-
           compile_schema(branch, branch_path, depth + 1, stats, max_depth, max_properties) do
      {:ok, %{kind: :nullable, schema: compiled_branch}, final_stats}
    end
  end

  defp nullable_any_of_branch(schema, path) do
    case Map.get(schema, "anyOf") do
      [left, right] ->
        if plain_schema_map?(left) and plain_schema_map?(right) do
          pick_nullable_any_of_branch([left, right], path)
        else
          unsupported_nullable_any_of(path)
        end

      _ ->
        unsupported_nullable_any_of(path)
    end
  end

  defp pick_nullable_any_of_branch(branches, path) do
    indexed = Enum.with_index(branches)
    null_branches = Enum.filter(indexed, fn {branch, _idx} -> null_schema?(branch) end)
    non_null_branches = Enum.reject(indexed, fn {branch, _idx} -> null_schema?(branch) end)

    case {null_branches, non_null_branches} do
      {[{null_branch, null_idx}], [{branch, branch_idx}]} ->
        with :ok <-
               reject_unknown_schema_keys(
                 stringify_schema_keys(null_branch),
                 @null_schema_keys,
                 path ++ ["anyOf", null_idx]
               ) do
          {:ok, branch, path ++ ["anyOf", branch_idx]}
        end

      _ ->
        unsupported_nullable_any_of(path)
    end
  end

  defp plain_schema_map?(value), do: is_map(value) and not is_struct(value)

  defp null_schema?(schema) do
    schema
    |> stringify_schema_keys()
    |> Map.get("type")
    |> Kernel.==("null")
  end

  defp unsupported_nullable_any_of(path) do
    {:error,
     error(
       :unsupported_schema,
       "anyOf is only supported for nullable schemas with one null branch",
       path
     )}
  end

  defp validate_value(%{kind: :object} = schema, value, path) do
    cond do
      not is_map(value) or is_struct(value) ->
        {:error, error(:invalid_type, "expected object", path)}

      Enum.any?(Map.keys(value), &(not is_binary(&1))) ->
        {:error, error(:invalid_key_type, "all object keys must be strings", path)}

      true ->
        case missing_required_keys(schema.required, value) do
          [missing | _] ->
            {:error, error(:missing_required, "missing required key #{inspect(missing)}", path)}

          [] ->
            validate_object_entries(schema, value, path)
        end
    end
  end

  defp validate_value(%{kind: :array} = schema, value, path) do
    cond do
      not is_list(value) ->
        {:error, error(:invalid_type, "expected array", path)}

      is_integer(schema.min_items) and length(value) < schema.min_items ->
        {:error, error(:invalid_length, "array length below minItems", path)}

      is_integer(schema.max_items) and length(value) > schema.max_items ->
        {:error, error(:invalid_length, "array length above maxItems", path)}

      true ->
        Enum.with_index(value)
        |> Enum.reduce_while(:ok, fn {entry, idx}, :ok ->
          case validate_value(schema.items, entry, path ++ [idx]) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp validate_value(%{kind: :nullable}, nil, _path), do: :ok

  defp validate_value(%{kind: :nullable, schema: schema}, value, path) do
    validate_value(schema, value, path)
  end

  defp validate_value(%{kind: kind} = schema, value, path)
       when kind in [:string, :integer, :number, :boolean] do
    with :ok <- validate_scalar_type(kind, value, path),
         :ok <- validate_enum(schema.enum, value, path),
         :ok <- validate_string_bounds(schema, value, path),
         :ok <- validate_numeric_bounds(schema, value, path) do
      :ok
    end
  end

  defp validate_value(_schema, _value, path) do
    {:error, error(:invalid_schema, "compiled schema is invalid", path)}
  end

  defp validate_object_entries(schema, value, path) do
    Enum.reduce_while(value, :ok, fn {key, entry}, :ok ->
      case Map.fetch(schema.properties, key) do
        {:ok, child_schema} ->
          case validate_value(child_schema, entry, path ++ [key]) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        :error ->
          {:halt, {:error, error(:unknown_key, "unknown key #{inspect(key)}", path)}}
      end
    end)
  end

  defp missing_required_keys(required_set, value) do
    required_set
    |> Enum.reject(&Map.has_key?(value, &1))
    |> Enum.sort()
  end

  defp validate_scalar_type(:string, value, _path) when is_binary(value), do: :ok
  defp validate_scalar_type(:integer, value, _path) when is_integer(value), do: :ok
  defp validate_scalar_type(:number, value, _path) when is_number(value), do: :ok
  defp validate_scalar_type(:boolean, value, _path) when is_boolean(value), do: :ok

  defp validate_scalar_type(kind, _value, path) do
    {:error, error(:invalid_type, "expected #{kind}", path)}
  end

  defp validate_enum(nil, _value, _path), do: :ok

  defp validate_enum(enum, value, path) when is_list(enum) do
    if value in enum do
      :ok
    else
      {:error, error(:invalid_enum, "value is not in enum set", path)}
    end
  end

  defp validate_string_bounds(_schema, value, _path) when not is_binary(value), do: :ok

  defp validate_string_bounds(schema, value, path) do
    cond do
      is_integer(schema.min_length) and String.length(value) < schema.min_length ->
        {:error, error(:invalid_length, "string shorter than minLength", path)}

      is_integer(schema.max_length) and String.length(value) > schema.max_length ->
        {:error, error(:invalid_length, "string longer than maxLength", path)}

      true ->
        :ok
    end
  end

  defp validate_numeric_bounds(_schema, value, _path) when not is_number(value), do: :ok

  defp validate_numeric_bounds(schema, value, path) do
    cond do
      is_number(schema.minimum) and value < schema.minimum ->
        {:error, error(:out_of_range, "number below minimum", path)}

      is_number(schema.maximum) and value > schema.maximum ->
        {:error, error(:out_of_range, "number above maximum", path)}

      true ->
        :ok
    end
  end

  defp reject_unsupported_constructs(schema, path) do
    case Enum.find(@unsupported_constructs, &Map.has_key?(schema, &1)) do
      nil ->
        :ok

      key ->
        {:error, error(:unsupported_schema, "unsupported schema construct #{inspect(key)}", path)}
    end
  end

  defp reject_unknown_keys(schema, "object", path),
    do: reject_unknown_schema_keys(schema, @object_schema_keys, path)

  defp reject_unknown_keys(schema, "array", path),
    do: reject_unknown_schema_keys(schema, @array_schema_keys, path)

  defp reject_unknown_keys(schema, "string", path),
    do: reject_unknown_schema_keys(schema, @string_schema_keys, path)

  defp reject_unknown_keys(schema, "integer", path),
    do: reject_unknown_schema_keys(schema, @integer_schema_keys, path)

  defp reject_unknown_keys(schema, "number", path),
    do: reject_unknown_schema_keys(schema, @number_schema_keys, path)

  defp reject_unknown_keys(schema, "boolean", path),
    do: reject_unknown_schema_keys(schema, @boolean_schema_keys, path)

  defp reject_unknown_keys(_schema, _type, _path), do: :ok

  defp reject_unknown_schema_keys(schema, allowed_keys, path) do
    unknown =
      schema
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed_keys))

    case unknown do
      [] ->
        :ok

      [key | _] ->
        {:error, error(:unsupported_schema, "unsupported schema keyword #{inspect(key)}", path)}
    end
  end

  defp infer_schema_type(schema) do
    case Map.get(schema, "type") do
      type when is_binary(type) -> type
      nil -> infer_schema_type_without_type(schema)
      _ -> nil
    end
  end

  defp infer_schema_type_without_type(schema) do
    cond do
      Map.has_key?(schema, "properties") -> "object"
      Map.has_key?(schema, "items") -> "array"
      true -> nil
    end
  end

  defp normalize_enum(nil, _type, _path), do: {:ok, nil}

  defp normalize_enum(enum, type, path) when is_list(enum) do
    if Enum.all?(enum, &enum_value_matches_type?(&1, type)) do
      {:ok, enum}
    else
      {:error, error(:invalid_schema, "enum values do not match declared type", path)}
    end
  end

  defp normalize_enum(_enum, _type, path) do
    {:error, error(:invalid_schema, "enum must be a list", path)}
  end

  defp enum_value_matches_type?(value, "string"), do: is_binary(value)
  defp enum_value_matches_type?(value, "integer"), do: is_integer(value)
  defp enum_value_matches_type?(value, "number"), do: is_number(value)
  defp enum_value_matches_type?(value, "boolean"), do: is_boolean(value)
  defp enum_value_matches_type?(_value, _type), do: false

  defp normalize_non_negative_int(nil, _name, _path), do: {:ok, nil}

  defp normalize_non_negative_int(value, _name, _path) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp normalize_non_negative_int(_value, name, path) do
    {:error, error(:invalid_schema, "#{name} must be a non-negative integer", path)}
  end

  defp normalize_number(nil, _name, _path), do: {:ok, nil}
  defp normalize_number(value, _name, _path) when is_number(value), do: {:ok, value}

  defp normalize_number(_value, name, path) do
    {:error, error(:invalid_schema, "#{name} must be a number", path)}
  end

  defp validate_item_bounds(nil, _max, _path), do: :ok
  defp validate_item_bounds(_min, nil, _path), do: :ok

  defp validate_item_bounds(min, max, _path) when min <= max, do: :ok

  defp validate_item_bounds(_min, _max, path) do
    {:error, error(:invalid_schema, "minimum cannot exceed maximum", path)}
  end

  defp validate_number_bounds(nil, _max, _path), do: :ok
  defp validate_number_bounds(_min, nil, _path), do: :ok

  defp validate_number_bounds(min, max, _path) when min <= max, do: :ok

  defp validate_number_bounds(_min, _max, path) do
    {:error, error(:invalid_schema, "minimum cannot exceed maximum", path)}
  end

  defp stringify_schema_keys(schema) do
    Enum.reduce(schema, %{}, fn {key, value}, acc ->
      string_key =
        case key do
          key when is_binary(key) -> key
          key when is_atom(key) -> Atom.to_string(key)
          _ -> to_string(key)
        end

      Map.put(acc, string_key, value)
    end)
  end

  defp normalize_limit(value, _fallback) when is_integer(value) and value > 0, do: value
  defp normalize_limit(_value, fallback), do: fallback

  defp error(code, message, path), do: %{code: code, message: message, path: path}
end
