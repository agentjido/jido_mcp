defmodule Jido.MCP.JidoAI.JSONSchemaToZoi do
  @moduledoc false

  @type convert_result :: %{schema_ast: Macro.t(), warnings: [String.t()]}

  @spec convert(map() | nil) :: convert_result()
  def convert(nil), do: %{schema_ast: quote(do: Zoi.map()), warnings: ["missing schema"]}

  def convert(%{} = schema) do
    case object_schema(schema) do
      {:ok, ast} -> %{schema_ast: ast, warnings: []}
      {:error, reason} -> %{schema_ast: quote(do: Zoi.map()), warnings: [reason]}
    end
  end

  def convert(_), do: %{schema_ast: quote(do: Zoi.map()), warnings: ["schema is not a map"]}

  defp object_schema(%{"type" => "object"} = schema) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", []) |> MapSet.new()

    if is_map(properties) do
      fields =
        Enum.map(properties, fn {name, value_schema} ->
          key = safe_to_atom(name)
          required? = MapSet.member?(required, name)
          {key, field_schema(value_schema, required?)}
        end)

      {:ok, quote(do: Zoi.object(%{unquote_splicing(fields)}))}
    else
      {:error, "object schema has invalid properties"}
    end
  end

  defp object_schema(%{}), do: {:error, "root schema is not an object"}

  defp field_schema(%{} = schema, required?) do
    base = base_type(schema)
    base = maybe_default(base, schema)
    maybe_optional(base, required?)
  end

  defp field_schema(_, required?) do
    maybe_optional(quote(do: Zoi.any()), required?)
  end

  defp base_type(%{"enum" => _values}) do
    quote do: Zoi.any()
  end

  defp base_type(%{"type" => "string"}), do: quote(do: Zoi.string())
  defp base_type(%{"type" => "integer"}), do: quote(do: Zoi.integer())
  defp base_type(%{"type" => "number"}), do: quote(do: Zoi.number())
  defp base_type(%{"type" => "boolean"}), do: quote(do: Zoi.boolean())

  defp base_type(%{"type" => "array"} = schema) do
    item = field_schema(Map.get(schema, "items", %{}), true)
    quote do: Zoi.list(unquote(item))
  end

  defp base_type(%{"type" => "object"} = schema) do
    case object_schema(schema) do
      {:ok, ast} -> ast
      {:error, _} -> quote(do: Zoi.map())
    end
  end

  defp base_type(_), do: quote(do: Zoi.any())

  defp maybe_default(ast, %{"default" => default}) do
    quote do
      unquote(ast)
      |> Zoi.default(unquote(default))
    end
  end

  defp maybe_default(ast, _), do: ast

  defp maybe_optional(ast, true), do: ast

  defp maybe_optional(ast, false) do
    quote do
      unquote(ast)
      |> Zoi.optional()
    end
  end

  defp safe_to_atom(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9_]/u, "_")
    |> then(fn
      "" -> :value
      normalized -> String.to_atom(normalized)
    end)
  end
end
