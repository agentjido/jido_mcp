defmodule Jido.MCP.Server.Runtime do
  @moduledoc false

  alias ExMCP.Error
  alias Jido.Action.Schema
  alias Jido.MCP.Server.Context

  @invalid_request -32_600
  @invalid_params -32_602
  @server_error -32_000

  @spec init_state(term()) :: map()
  def init_state(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: %{assigns: Keyword.get(opts, :assigns, %{})},
      else: %{assigns: %{}}
  end

  def init_state(%{} = opts), do: %{assigns: Map.get(opts, :assigns, %{})}
  def init_state(_opts), do: %{assigns: %{}}

  @spec list_tools([module()], term()) :: {:ok, [map()], nil, term()} | {:error, term(), term()}
  def list_tools(modules, state), do: definitions(modules, &tool_definition/1, state)

  @spec list_resources([module()], term()) ::
          {:ok, [map()], nil, term()} | {:error, term(), term()}
  def list_resources(modules, state), do: definitions(modules, &resource_definition/1, state)

  @spec list_prompts([module()], term()) ::
          {:ok, [map()], nil, term()} | {:error, term(), term()}
  def list_prompts(modules, state), do: definitions(modules, &prompt_definition/1, state)

  @spec handle_tool_call([module()], String.t(), map(), term(), module()) ::
          {:ok, map(), term()} | {:error, term(), term()}
  def handle_tool_call(tool_modules, name, arguments, state, server_module)
      when is_list(tool_modules) and is_binary(name) and is_map(arguments) do
    context = Context.new(state)

    try do
      with :ok <-
             authorize(
               server_module,
               %{type: :tool_call, name: name, arguments: arguments},
               context
             ),
           {:ok, module} <- find_module(tool_modules, :name, name) do
        case Jido.Exec.run(module, arguments, action_context(context)) do
          {:ok, output} -> {:ok, tool_response(output), state}
          {:ok, output, _directives} -> {:ok, tool_response(output), state}
          {:error, _reason} -> {:ok, tool_error_response(), state}
          {:error, _reason, _directives} -> {:ok, tool_error_response(), state}
        end
      else
        {:error, :not_found} ->
          protocol_error(@invalid_params, "Tool not found", state)

        {:error, :unauthorized} ->
          protocol_error(@invalid_request, "Unauthorized tool call", state)
      end
    rescue
      _exception -> protocol_error(@server_error, "Tool call execution failed", state)
    catch
      _kind, _reason -> protocol_error(@server_error, "Tool call execution failed", state)
    end
  end

  @spec handle_resource_read([module()], String.t(), term(), module()) ::
          {:ok, map(), term()} | {:error, term(), term()}
  def handle_resource_read(resource_modules, uri, state, server_module)
      when is_list(resource_modules) and is_binary(uri) do
    context = Context.new(state)

    try do
      with :ok <- authorize(server_module, %{type: :resource_read, uri: uri}, context),
           {:ok, module} <- find_module(resource_modules, :uri, uri),
           {:ok, content} <- module.read(uri, context),
           {:ok, response} <- resource_response(module, uri, content) do
        {:ok, response, state}
      else
        {:error, :not_found} ->
          protocol_error(@invalid_params, "Resource not found", state)

        {:error, :unauthorized} ->
          protocol_error(@invalid_request, "Unauthorized resource read", state)

        {:error, _reason} ->
          protocol_error(@server_error, "Resource read failed", state)

        _other ->
          protocol_error(@server_error, "Resource read failed", state)
      end
    rescue
      _exception -> protocol_error(@server_error, "Resource read failed", state)
    catch
      _kind, _reason -> protocol_error(@server_error, "Resource read failed", state)
    end
  end

  @spec handle_prompt_get([module()], String.t(), map(), term(), module()) ::
          {:ok, map(), term()} | {:error, term(), term()}
  def handle_prompt_get(prompt_modules, name, arguments, state, server_module)
      when is_list(prompt_modules) and is_binary(name) and is_map(arguments) do
    context = Context.new(state)

    try do
      with :ok <-
             authorize(
               server_module,
               %{type: :prompt_get, name: name, arguments: arguments},
               context
             ),
           {:ok, module} <- find_module(prompt_modules, :name, name),
           {:ok, messages} when is_list(messages) <- module.messages(arguments, context) do
        {:ok, %{messages: Enum.map(messages, &normalize_prompt_message/1)}, state}
      else
        {:error, :not_found} ->
          protocol_error(@invalid_params, "Prompt not found", state)

        {:error, :unauthorized} ->
          protocol_error(@invalid_request, "Unauthorized prompt access", state)

        {:error, _reason} ->
          protocol_error(@server_error, "Prompt rendering failed", state)

        _other ->
          protocol_error(@server_error, "Prompt rendering failed", state)
      end
    rescue
      _exception -> protocol_error(@server_error, "Prompt rendering failed", state)
    catch
      _kind, _reason -> protocol_error(@server_error, "Prompt rendering failed", state)
    end
  end

  defp definitions(modules, mapper, state) do
    {:ok, Enum.map(modules, mapper), nil, state}
  rescue
    _exception -> protocol_error(@server_error, "Server capability discovery failed", state)
  catch
    _kind, _reason -> protocol_error(@server_error, "Server capability discovery failed", state)
  end

  defp tool_definition(module) do
    %{
      name: module.name(),
      description: maybe_description(module),
      inputSchema: action_input_schema(module)
    }
  end

  defp resource_definition(module) do
    %{
      uri: module.uri(),
      name: module.name(),
      title: module.name(),
      description: module.description(),
      mimeType: module.mime_type()
    }
  end

  defp prompt_definition(module) do
    %{
      name: module.name(),
      description: module.description(),
      arguments: prompt_arguments(module.arguments_schema())
    }
  end

  defp prompt_arguments(schema) when is_map(schema) do
    schema
    |> Enum.map(fn {name, value} -> prompt_argument(name, value) end)
    |> Enum.sort_by(& &1.name)
  end

  defp prompt_arguments(_schema), do: []

  defp prompt_argument(name, {:required, _type}),
    do: %{name: to_string(name), required: true}

  defp prompt_argument(name, value) when is_list(value) do
    %{name: to_string(name), required: Keyword.get(value, :required, false)}
    |> maybe_put(:description, Keyword.get(value, :description))
  end

  defp prompt_argument(name, %{} = value) do
    required = Map.get(value, :required, Map.get(value, "required", false))
    description = Map.get(value, :description, Map.get(value, "description"))

    %{name: to_string(name), required: required == true}
    |> maybe_put(:description, description)
  end

  defp prompt_argument(name, _value), do: %{name: to_string(name), required: false}

  defp find_module(modules, function, value) do
    case Enum.find(
           modules,
           &(function_exported?(&1, function, 0) and apply(&1, function, []) == value)
         ) do
      nil -> {:error, :not_found}
      module -> {:ok, module}
    end
  end

  defp tool_response(%{} = output) do
    %{
      content: [%{type: "text", text: encoded_text(output)}],
      structuredContent: output
    }
  end

  defp tool_error_response do
    %{
      content: [%{type: "text", text: "Tool execution failed"}],
      isError: true
    }
  end

  defp resource_response(module, uri, output) when is_binary(output) do
    {:ok, %{uri: uri, mimeType: module.mime_type(), text: output}}
  end

  defp resource_response(module, uri, output) when is_map(output) or is_list(output) do
    case Jason.encode(output) do
      {:ok, text} -> {:ok, %{uri: uri, mimeType: module.mime_type(), text: text}}
      {:error, _reason} -> {:error, :invalid_content}
    end
  end

  defp resource_response(_module, _uri, _output), do: {:error, :invalid_content}

  defp normalize_prompt_message(%{"role" => role, "content" => content}),
    do: prompt_message(role, content)

  defp normalize_prompt_message(%{role: role, content: content}),
    do: prompt_message(role, content)

  defp normalize_prompt_message(content) when is_binary(content),
    do: prompt_message("user", content)

  defp normalize_prompt_message(_other),
    do: prompt_message("user", "Prompt content is unavailable")

  defp prompt_message(role, content) do
    %{role: normalize_role(role), content: normalize_prompt_content(content)}
  end

  defp normalize_role(role) when role in ["assistant", :assistant], do: "assistant"
  defp normalize_role(_role), do: "user"

  defp normalize_prompt_content(%{"type" => type} = content) when is_binary(type), do: content
  defp normalize_prompt_content(%{type: type} = content) when is_binary(type), do: content

  defp normalize_prompt_content(content) when is_binary(content),
    do: %{type: "text", text: content}

  defp normalize_prompt_content(content), do: %{type: "text", text: encoded_text(content)}

  defp encoded_text(value) do
    case Jason.encode(value) do
      {:ok, text} -> text
      {:error, _reason} -> "Result is not JSON encodable"
    end
  end

  defp action_context(%Context{} = context) do
    %{
      mcp_frame: context,
      mcp_context: context.context,
      transport: context.transport,
      request: context.request,
      assigns: context.assigns
    }
  end

  defp action_input_schema(module) do
    module.schema()
    |> Schema.to_json_schema()
    |> strict_tool_input()
  rescue
    _exception -> %{"type" => "object", "properties" => %{}, "required" => []}
  end

  # Tool arguments are always closed at the root. Nested schemas keep the
  # module-defined JSON Schema semantics, including intentionally open objects.
  defp strict_tool_input(%{type: :object} = schema),
    do: Map.put(schema, :additionalProperties, false)

  defp strict_tool_input(%{"type" => "object"} = schema),
    do: Map.put(schema, "additionalProperties", false)

  defp strict_tool_input(schema),
    do: Map.put(schema, "additionalProperties", false)

  defp maybe_description(module) do
    if function_exported?(module, :description, 0), do: module.description(), else: nil
  end

  defp authorize(server_module, request, context) do
    case server_module.authorize(request, context) do
      :ok -> :ok
      true -> :ok
      _other -> {:error, :unauthorized}
    end
  rescue
    _exception -> {:error, :unauthorized}
  catch
    _kind, _reason -> {:error, :unauthorized}
  end

  defp protocol_error(code, message, state) do
    {:error, Error.protocol_error(code, message), state}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
