defmodule Jido.MCP.Server do
  @moduledoc """
  Macro for exposing explicit allowlisted Jido capabilities as an MCP server.

  ## Example

      defmodule MyApp.MCPServer do
        use Jido.MCP.Server,
          name: "my-app",
          version: "1.0.0",
          publish: %{
            tools: [MyApp.Actions.Search],
            resources: [MyApp.MCP.Resources.ReleaseNotes],
            prompts: [MyApp.MCP.Prompts.CodeReview]
          }
      end
  """

  @type server_child :: module() | {module(), keyword()}

  @spec server_children(module(), keyword()) :: [server_child()]
  def server_children(server_module, opts \\ []) when is_atom(server_module) and is_list(opts) do
    transport = Keyword.get(opts, :transport, :stdio)
    server_opts = Keyword.get(opts, :server_opts, [])

    [
      Anubis.Server.Registry,
      {server_module, Keyword.put(server_opts, :transport, transport)}
    ]
  end

  @spec plug_init_opts(module()) :: keyword()
  def plug_init_opts(server_module) when is_atom(server_module) do
    [server: server_module]
  end

  defp normalize_publish!(publish, caller) do
    publish =
      cond do
        is_map(publish) ->
          publish

        is_list(publish) and Keyword.keyword?(publish) ->
          Enum.into(publish, %{})

        true ->
          case Code.eval_quoted(publish, [], caller) do
            {value, _binding} when is_map(value) ->
              value

            {value, _binding} when is_list(value) ->
              if Keyword.keyword?(value) do
                Enum.into(value, %{})
              else
                raise ArgumentError,
                      "publish must evaluate to a map or keyword list, got: #{inspect(value)}"
              end

            {value, _binding} ->
              raise ArgumentError,
                    "publish must evaluate to a map or keyword list, got: #{inspect(value)}"
          end
      end

    %{
      tools: List.wrap(Map.get(publish, :tools, [])),
      resources: List.wrap(Map.get(publish, :resources, [])),
      prompts: List.wrap(Map.get(publish, :prompts, []))
    }
  end

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    version = Keyword.fetch!(opts, :version)
    publish = normalize_publish!(Keyword.get(opts, :publish, %{}), __CALLER__)

    tools = publish.tools
    resources = publish.resources
    prompts = publish.prompts

    capabilities = []
    capabilities = if tools != [], do: capabilities ++ [:tools], else: capabilities
    capabilities = if resources != [], do: capabilities ++ [:resources], else: capabilities
    capabilities = if prompts != [], do: capabilities ++ [:prompts], else: capabilities

    quote generated: true,
          bind_quoted: [
            name: name,
            version: version,
            tools: tools,
            resources: resources,
            prompts: prompts,
            capabilities: capabilities
          ] do
      use Anubis.Server,
        name: name,
        version: version,
        capabilities: capabilities

      @publish_tools tools
      @publish_resources resources
      @publish_prompts prompts

      @doc false
      def __publish__,
        do: %{tools: @publish_tools, resources: @publish_resources, prompts: @publish_prompts}

      @impl true
      def init(_client_info, frame) do
        frame = Enum.reduce(@publish_tools, frame, &Jido.MCP.Server.Runtime.register_tool(&2, &1))

        frame =
          Enum.reduce(
            @publish_resources,
            frame,
            &Jido.MCP.Server.Runtime.register_resource(&2, &1)
          )

        frame =
          Enum.reduce(@publish_prompts, frame, &Jido.MCP.Server.Runtime.register_prompt(&2, &1))

        {:ok, frame}
      end

      @impl true
      def handle_tool_call(name, arguments, frame) do
        Jido.MCP.Server.Runtime.handle_tool_call(
          @publish_tools,
          name,
          arguments,
          frame,
          __MODULE__
        )
      end

      @impl true
      def handle_resource_read(uri, frame) do
        Jido.MCP.Server.Runtime.handle_resource_read(@publish_resources, uri, frame, __MODULE__)
      end

      @impl true
      def handle_prompt_get(name, arguments, frame) do
        Jido.MCP.Server.Runtime.handle_prompt_get(
          @publish_prompts,
          name,
          arguments,
          frame,
          __MODULE__
        )
      end

      @doc """
      Optional authorization callback.

      Return `:ok` (or `true`) to allow the request, anything else to deny.
      """
      @spec authorize(map(), Anubis.Server.Frame.t()) :: :ok | true | term()
      def authorize(_request, _frame), do: :ok

      defoverridable authorize: 2
    end
  end
end
