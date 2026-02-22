defmodule Jido.MCP.JidoAI.ProxyGenerator do
  @moduledoc false

  alias Jido.MCP.JidoAI.JSONSchemaToZoi

  @spec build_modules(atom(), [map()], keyword()) ::
          {:ok, [module()], %{module() => [String.t()]}} | {:error, term()}
  def build_modules(endpoint_id, tools, opts \\ [])
      when is_atom(endpoint_id) and is_list(tools) do
    prefix = Keyword.get(opts, :prefix, "mcp_#{endpoint_id}_")

    {modules, warnings} =
      Enum.reduce(tools, {[], %{}}, fn tool, {mods, warning_acc} ->
        with name when is_binary(name) <- Map.get(tool, "name"),
             module <- module_name(endpoint_id, name),
             local_name <- local_tool_name(prefix, name),
             description <- Map.get(tool, "description") || "MCP proxy tool #{name}",
             %{schema_ast: schema_ast, warnings: schema_warnings} <-
               JSONSchemaToZoi.convert(Map.get(tool, "inputSchema")) do
          module =
            ensure_proxy_module(module, endpoint_id, name, local_name, description, schema_ast)

          warning_acc =
            if schema_warnings == [],
              do: warning_acc,
              else: Map.put(warning_acc, module, schema_warnings)

          {[module | mods], warning_acc}
        else
          _ -> {mods, warning_acc}
        end
      end)

    {:ok, Enum.reverse(modules), warnings}
  end

  defp ensure_proxy_module(module, endpoint_id, remote_name, local_name, description, schema_ast)
       when is_atom(module) do
    if Code.ensure_loaded?(module) do
      module
    else
      create_proxy_module(module, endpoint_id, remote_name, local_name, description, schema_ast)
    end
  end

  defp create_proxy_module(module, endpoint_id, remote_name, local_name, description, schema_ast) do
    quoted =
      quote location: :keep do
        use Jido.Action,
          name: unquote(local_name),
          description: unquote(description),
          schema: unquote(schema_ast)

        @endpoint_id unquote(endpoint_id)
        @remote_tool_name unquote(remote_name)

        @impl true
        def run(params, _context) do
          case Jido.MCP.call_tool(@endpoint_id, @remote_tool_name, params) do
            {:ok, %{data: data}} -> {:ok, data}
            {:error, error} -> {:error, error}
          end
        end
      end

    {:module, created, _bytecode, _result} =
      Module.create(module, quoted, Macro.Env.location(__ENV__))

    created
  end

  defp module_name(endpoint_id, remote_name) do
    endpoint = endpoint_id |> Atom.to_string() |> Macro.camelize()
    tool = remote_name |> sanitize_segment() |> Macro.camelize()
    Module.concat([Jido, MCP, JidoAI, Proxy, endpoint, tool])
  end

  defp local_tool_name(prefix, remote_name), do: prefix <> sanitize_segment(remote_name)

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
