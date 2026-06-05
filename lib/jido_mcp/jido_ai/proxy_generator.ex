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
    adapter = Keyword.get(opts, :schema_adapter, SchemaAdapter.JSV)

    {modules, warnings, skipped} =
      Enum.reduce(tools, {[], %{}, []}, fn tool, {mods, warning_acc, skipped_acc} ->
        with name when is_binary(name) <- Map.get(tool, "name"),
             local_name <- local_tool_name(prefix, name),
             description <- Map.get(tool, "description") || "MCP proxy tool #{name}",
             {:ok, compiled_schema} <-
               adapter.compile(Map.get(tool, "inputSchema"),
                 max_depth: max_schema_depth,
                 max_properties: max_schema_properties
               ) do
          action_schema = action_schema(Map.get(tool, "inputSchema"))

          module =
            module_name(
              endpoint_id,
              local_name,
              name,
              description,
              compiled_schema,
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
        else
          {:error, reason} ->
            tool_name = Map.get(tool, "name", "<unnamed>")
            warning = "tool schema rejected: #{inspect(reason)}"
            skipped = %{tool_name: tool_name, reason: warning}
            {mods, Map.put(warning_acc, tool_name, [warning]), [skipped | skipped_acc]}

          _ ->
            warning = "tool schema rejected: missing or invalid tool name"
            skipped = %{tool_name: "<unnamed>", reason: warning}
            {mods, Map.put(warning_acc, "<unnamed>", [warning]), [skipped | skipped_acc]}
        end
      end)

    {:ok, Enum.reverse(modules), warnings, Enum.reverse(skipped)}
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
    compiled_schema = Macro.escape(compiled_schema)
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
        @compiled_input_schema unquote(compiled_schema)
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
          case @schema_adapter.validate(@compiled_input_schema, params) do
            :ok -> {:ok, params}
            {:ok, validated_params} when is_map(validated_params) -> {:ok, validated_params}
            {:error, error} -> {:error, error}
            other -> {:error, {:unexpected_schema_adapter_response, other}}
          end
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
         compiled_schema,
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
        compiled_schema,
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
         compiled_schema,
         action_schema,
         adapter
       ) do
    {remote_name, local_name, description, compiled_schema, action_schema, adapter}
    |> :erlang.phash2()
    |> Integer.to_string(36)
    |> String.upcase()
  end

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
