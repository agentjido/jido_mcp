defmodule Jido.MCP.JidoAI.ProxyGenerator do
  @moduledoc false

  alias Jido.MCP.SchemaAdapter

  @spec build_modules(atom(), [map()], keyword()) ::
          {:ok, [module()], %{term() => [String.t()]}, [map()]} | {:error, term()}
  def build_modules(endpoint_id, tools, opts \\ [])
      when is_atom(endpoint_id) and is_list(tools) do
    prefix =
      case Keyword.get(opts, :prefix) do
        value when is_binary(value) and value != "" -> value
        _ -> "mcp_#{endpoint_id}_"
      end

    max_schema_depth = Keyword.get(opts, :max_schema_depth, 8)
    max_schema_properties = Keyword.get(opts, :max_schema_properties, 200)

    with {:ok, adapter} <- schema_adapter(opts) do
      {modules, warnings, skipped} =
        Enum.reduce(tools, {[], %{}, []}, fn tool, acc ->
          build_tool_module(
            endpoint_id,
            tool,
            prefix,
            adapter,
            max_schema_depth,
            max_schema_properties,
            acc
          )
        end)

      {:ok, Enum.reverse(modules), warnings, Enum.reverse(skipped)}
    end
  end

  defp schema_adapter(opts) do
    adapter = Keyword.get(opts, :schema_adapter, SchemaAdapter.JSV)

    with true <- is_atom(adapter),
         {:module, ^adapter} <- Code.ensure_loaded(adapter),
         true <- function_exported?(adapter, :compile, 2),
         true <- function_exported?(adapter, :validate, 2) do
      {:ok, adapter}
    else
      _ -> {:error, {:invalid_schema_adapter, adapter}}
    end
  end

  defp build_tool_module(
         endpoint_id,
         tool,
         prefix,
         adapter,
         max_schema_depth,
         max_schema_properties,
         {mods, warning_acc, skipped_acc}
       ) do
    case Map.get(tool, "name") do
      name when is_binary(name) ->
        compile_tool_schema(
          endpoint_id,
          tool,
          name,
          prefix,
          adapter,
          max_schema_depth,
          max_schema_properties,
          {mods, warning_acc, skipped_acc}
        )

      _ ->
        warning = "tool schema rejected: missing or invalid tool name"
        skipped = %{tool_name: "<unnamed>", reason: warning}
        {mods, Map.put(warning_acc, "<unnamed>", [warning]), [skipped | skipped_acc]}
    end
  end

  defp compile_tool_schema(
         endpoint_id,
         tool,
         name,
         prefix,
         adapter,
         max_schema_depth,
         max_schema_properties,
         acc
       ) do
    case adapter.compile(Map.get(tool, "inputSchema"),
           max_depth: max_schema_depth,
           max_properties: max_schema_properties
         ) do
      {:ok, compiled_schema} ->
        create_tool_module(endpoint_id, tool, name, prefix, adapter, compiled_schema, acc)

      {:error, reason} ->
        skip_tool(name, "tool schema rejected: #{inspect(reason)}", acc)

      other ->
        skip_tool(
          name,
          "tool schema rejected: unexpected schema adapter response #{inspect(other)}",
          acc
        )
    end
  end

  defp create_tool_module(
         endpoint_id,
         tool,
         name,
         prefix,
         adapter,
         compiled_schema,
         {mods, warning_acc, skipped_acc}
       ) do
    local_name = local_tool_name(prefix, name)
    description = Map.get(tool, "description") || "MCP proxy tool #{name}"
    action_schema = action_schema(Map.get(tool, "inputSchema"))

    module =
      module_name(
        endpoint_id,
        local_name,
        name,
        description,
        action_schema,
        adapter
      )

    module =
      ensure_proxy_module(
        module,
        endpoint_id,
        name,
        local_name,
        description,
        compiled_schema,
        action_schema,
        adapter
      )

    {[module | mods], warning_acc, skipped_acc}
  end

  defp skip_tool(tool_name, warning, {mods, warning_acc, skipped_acc}) do
    skipped = %{tool_name: tool_name, reason: warning}
    {mods, Map.put(warning_acc, tool_name, [warning]), [skipped | skipped_acc]}
  end

  defp ensure_proxy_module(
         module,
         endpoint_id,
         remote_name,
         local_name,
         description,
         compiled_schema,
         action_schema,
         adapter
       )
       when is_atom(module) do
    if Code.ensure_loaded?(module) do
      put_compiled_schema(module, compiled_schema)
      module
    else
      create_proxy_module(
        module,
        endpoint_id,
        remote_name,
        local_name,
        description,
        compiled_schema,
        action_schema,
        adapter
      )
    end
  end

  defp create_proxy_module(
         module,
         endpoint_id,
         remote_name,
         local_name,
         description,
         compiled_schema,
         action_schema,
         adapter
       ) do
    compiled_schema_key = module |> put_compiled_schema(compiled_schema) |> Macro.escape()
    action_schema = Macro.escape(action_schema)
    adapter = Macro.escape(adapter)

    quoted =
      quote location: :keep do
        use Jido.Action,
          name: unquote(local_name),
          description: unquote(description),
          schema: unquote(action_schema)

        @endpoint_id unquote(endpoint_id)
        @remote_tool_name unquote(remote_name)
        @compiled_input_schema_key unquote(compiled_schema_key)
        @schema_adapter unquote(adapter)

        @impl true
        def run(params, _context) do
          with {:ok, validated_params} <- validate_input(params),
               {:ok, %{data: data}} <-
                 Jido.MCP.call_tool(@endpoint_id, @remote_tool_name, validated_params) do
            {:ok, data}
          else
            {:error, error} -> {:error, error}
            other -> {:error, {:unexpected_proxy_response, other}}
          end
        end

        defp validate_input(params) do
          case @schema_adapter.validate(compiled_input_schema(), params) do
            :ok -> {:ok, params}
            {:ok, validated_params} when is_map(validated_params) -> {:ok, validated_params}
            {:error, error} -> {:error, error}
            other -> {:error, {:unexpected_schema_adapter_response, other}}
          end
        end

        defp compiled_input_schema do
          :persistent_term.get(@compiled_input_schema_key)
        end
      end

    {:module, created, _bytecode, _result} =
      Module.create(module, quoted, Macro.Env.location(__ENV__))

    created
  end

  defp module_name(
         endpoint_id,
         local_name,
         remote_name,
         description,
         action_schema,
         adapter
       ) do
    endpoint = endpoint_id |> Atom.to_string() |> Macro.camelize()
    tool = local_name |> sanitize_segment() |> Macro.camelize()

    hash =
      definition_hash(
        remote_name,
        local_name,
        description,
        action_schema,
        adapter
      )

    Module.concat([Jido, MCP, JidoAI, Proxy, endpoint, "#{tool}#{hash}"])
  end

  defp local_tool_name(prefix, remote_name), do: prefix <> sanitize_segment(remote_name)

  defp definition_hash(
         remote_name,
         local_name,
         description,
         action_schema,
         adapter
       ) do
    {remote_name, local_name, description, action_schema, adapter}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :upper)
    |> binary_part(0, 10)
  end

  defp put_compiled_schema(module, compiled_schema) do
    key = compiled_schema_key(module)
    :persistent_term.put(key, compiled_schema)
    key
  end

  defp compiled_schema_key(module), do: {__MODULE__, module, :compiled_input_schema}

  defp action_schema(nil), do: %{"type" => "object", "properties" => %{}}

  defp action_schema(%{} = schema) do
    schema
    |> stringify_schema_keys()
    |> Map.put_new("properties", %{})
  end

  defp stringify_schema_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_schema_keys(value)}
      {key, value} when is_binary(key) -> {key, stringify_schema_keys(value)}
      {key, value} -> {to_string(key), stringify_schema_keys(value)}
    end)
  end

  defp stringify_schema_keys(list) when is_list(list),
    do: Enum.map(list, &stringify_schema_keys/1)

  defp stringify_schema_keys(value), do: value

  defp sanitize_segment(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/u, "_")
    |> String.trim("_")
    |> case do
      "" -> "tool"
      normalized -> normalized
    end
  end
end
