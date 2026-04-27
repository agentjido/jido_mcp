defmodule Jido.MCP.Server.Runtime do
  @moduledoc false

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Jido.Action.Schema

  @spec register_tool(Frame.t(), module()) :: Frame.t()
  def register_tool(%Frame{} = frame, module) when is_atom(module) do
    Frame.register_tool(frame, module.name(),
      description: maybe_description(module),
      input_schema: action_input_schema(module)
    )
  end

  @spec register_resource(Frame.t(), module()) :: Frame.t()
  def register_resource(%Frame{} = frame, module) when is_atom(module) do
    Frame.register_resource(frame, module.uri(),
      name: module.name(),
      title: module.name(),
      description: module.description(),
      mime_type: module.mime_type()
    )
  end

  @spec register_prompt(Frame.t(), module()) :: Frame.t()
  def register_prompt(%Frame{} = frame, module) when is_atom(module) do
    Frame.register_prompt(frame, module.name(),
      description: module.description(),
      arguments: module.arguments_schema()
    )
  end

  @spec handle_tool_call([module()], String.t(), map(), Frame.t(), module()) ::
          {:reply, Response.t(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_tool_call(tool_modules, name, arguments, %Frame{} = frame, server_module)
      when is_list(tool_modules) and is_binary(name) and is_map(arguments) do
    try do
      with :ok <-
             authorize(
               server_module,
               %{type: :tool_call, name: name, arguments: arguments},
               frame
             ),
           {:ok, module} <- find_tool(tool_modules, name) do
        case Jido.Exec.run(module, arguments, build_action_context(frame)) do
          {:ok, output} ->
            {:reply, tool_response(output), frame}

          {:ok, output, _directives} ->
            {:reply, tool_response(output), frame}

          {:error, reason} ->
            {:reply, Response.tool() |> Response.error(inspect(reason)), frame}

          {:error, reason, _directives} ->
            {:reply, Response.tool() |> Response.error(inspect(reason)), frame}

          other ->
            {:reply,
             Response.tool() |> Response.error("Unexpected action result: #{inspect(other)}"),
             frame}
        end
      else
        {:error, :not_found} ->
          {:error, Error.protocol(:invalid_params, %{message: "Tool not found: #{name}"}), frame}

        {:error, :unauthorized} ->
          {:error, Error.protocol(:invalid_request, %{message: "Unauthorized tool call"}), frame}
      end
    rescue
      exception ->
        {:error,
         Error.execution("Tool call execution failed", %{
           name: name,
           reason: Exception.message(exception)
         }), frame}
    catch
      kind, reason ->
        {:error,
         Error.execution("Tool call execution failed", %{
           name: name,
           reason: inspect({kind, reason})
         }), frame}
    end
  end

  @spec handle_resource_read([module()], String.t(), Frame.t(), module()) ::
          {:reply, Response.t(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_resource_read(resource_modules, uri, %Frame{} = frame, server_module)
      when is_list(resource_modules) and is_binary(uri) do
    try do
      with :ok <- authorize(server_module, %{type: :resource_read, uri: uri}, frame),
           {:ok, module} <- find_resource(resource_modules, uri) do
        case module.read(uri, frame) do
          {:ok, content} ->
            {:reply, resource_response(content), frame}

          {:error, reason} ->
            {:error, Error.resource(:not_found, %{message: inspect(reason), uri: uri}), frame}

          other ->
            {:error,
             Error.execution("Resource read returned invalid result", %{
               uri: uri,
               result: inspect(other)
             }), frame}
        end
      else
        {:error, :not_found} ->
          {:error, Error.resource(:not_found, %{message: "Resource not found: #{uri}", uri: uri}),
           frame}

        {:error, :unauthorized} ->
          {:error, Error.protocol(:invalid_request, %{message: "Unauthorized resource read"}),
           frame}
      end
    rescue
      exception ->
        {:error,
         Error.execution("Resource read failed", %{
           uri: uri,
           reason: Exception.message(exception)
         }), frame}
    catch
      kind, reason ->
        {:error,
         Error.execution("Resource read failed", %{
           uri: uri,
           reason: inspect({kind, reason})
         }), frame}
    end
  end

  @spec handle_prompt_get([module()], String.t(), map(), Frame.t(), module()) ::
          {:reply, Response.t(), Frame.t()} | {:error, Error.t(), Frame.t()}
  def handle_prompt_get(prompt_modules, name, arguments, %Frame{} = frame, server_module)
      when is_list(prompt_modules) and is_binary(name) and is_map(arguments) do
    try do
      with :ok <-
             authorize(
               server_module,
               %{type: :prompt_get, name: name, arguments: arguments},
               frame
             ),
           {:ok, module} <- find_prompt(prompt_modules, name) do
        case module.messages(arguments, frame) do
          {:ok, messages} when is_list(messages) ->
            {:reply, prompt_response(messages), frame}

          {:error, reason} ->
            {:error, Error.execution("Prompt rendering failed", %{reason: inspect(reason)}),
             frame}

          other ->
            {:error,
             Error.execution("Prompt rendering returned invalid result", %{
               name: name,
               result: inspect(other)
             }), frame}
        end
      else
        {:error, :not_found} ->
          {:error, Error.protocol(:invalid_params, %{message: "Prompt not found: #{name}"}),
           frame}

        {:error, :unauthorized} ->
          {:error, Error.protocol(:invalid_request, %{message: "Unauthorized prompt access"}),
           frame}
      end
    rescue
      exception ->
        {:error,
         Error.execution("Prompt rendering failed", %{
           name: name,
           reason: Exception.message(exception)
         }), frame}
    catch
      kind, reason ->
        {:error,
         Error.execution("Prompt rendering failed", %{
           name: name,
           reason: inspect({kind, reason})
         }), frame}
    end
  end

  defp find_tool(modules, name) do
    case Enum.find(modules, &(function_exported?(&1, :name, 0) and &1.name() == name)) do
      nil -> {:error, :not_found}
      module -> {:ok, module}
    end
  end

  defp find_resource(modules, uri) do
    case Enum.find(modules, &(function_exported?(&1, :uri, 0) and &1.uri() == uri)) do
      nil -> {:error, :not_found}
      module -> {:ok, module}
    end
  end

  defp find_prompt(modules, name) do
    case Enum.find(modules, &(function_exported?(&1, :name, 0) and &1.name() == name)) do
      nil -> {:error, :not_found}
      module -> {:ok, module}
    end
  end

  defp tool_response(%{} = output), do: Response.tool() |> Response.structured(output)
  defp tool_response(output) when is_list(output), do: Response.tool() |> Response.json(output)
  defp tool_response(output) when is_binary(output), do: Response.tool() |> Response.text(output)
  defp tool_response(output), do: Response.tool() |> Response.text(inspect(output))

  defp resource_response(%{} = output), do: Response.resource() |> Response.json(output)

  defp resource_response(output) when is_list(output),
    do: Response.resource() |> Response.json(output)

  defp resource_response(output) when is_binary(output),
    do: Response.resource() |> Response.text(output)

  defp resource_response(output), do: Response.resource() |> Response.text(inspect(output))

  defp prompt_response(messages) when is_list(messages) do
    prompt = Response.prompt()

    Enum.reduce(messages, prompt, fn message, acc ->
      case normalize_prompt_message(message) do
        {"user", content} -> Response.user_message(acc, content)
        {"assistant", content} -> Response.assistant_message(acc, content)
        {"system", content} -> Response.system_message(acc, content)
        {_role, content} -> Response.user_message(acc, content)
      end
    end)
  end

  defp normalize_prompt_message(%{"role" => role, "content" => content}),
    do: {to_string(role), content}

  defp normalize_prompt_message(%{role: role, content: content}), do: {to_string(role), content}
  defp normalize_prompt_message(content) when is_binary(content), do: {"user", content}
  defp normalize_prompt_message(other), do: {"user", inspect(other)}

  defp build_action_context(%Frame{} = frame) do
    %{
      mcp_frame: frame,
      mcp_context: Map.get(frame, :context),
      transport: Map.get(frame, :transport, %{}),
      request: Map.get(frame, :request),
      assigns: Map.get(frame, :assigns, %{})
    }
  end

  defp action_input_schema(module) do
    module
    |> apply(:schema, [])
    |> Schema.to_json_schema(strict: true)
  rescue
    _ -> %{"type" => "object", "properties" => %{}, "required" => []}
  end

  defp maybe_description(module) do
    if function_exported?(module, :description, 0), do: module.description(), else: nil
  end

  defp authorize(server_module, request, frame) do
    try do
      if function_exported?(server_module, :authorize, 2) do
        case server_module.authorize(request, frame) do
          :ok -> :ok
          true -> :ok
          _ -> {:error, :unauthorized}
        end
      else
        :ok
      end
    rescue
      _ -> {:error, :unauthorized}
    catch
      _, _ -> {:error, :unauthorized}
    end
  end
end
