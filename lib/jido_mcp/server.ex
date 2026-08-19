defmodule Jido.MCP.Server do
  @moduledoc """
  Macro for exposing explicit allowlisted Jido capabilities as an ExMCP server.

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

    [{server_module, Keyword.put(server_opts, :transport, transport)}]
  end

  @spec plug_init_opts(module(), keyword()) :: keyword()
  def plug_init_opts(server_module, opts \\ []) when is_atom(server_module) and is_list(opts) do
    Keyword.put_new(opts, :server, server_module)
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

    capabilities =
      %{}
      |> maybe_capability(:tools, publish.tools)
      |> maybe_capability(:resources, publish.resources)
      |> maybe_capability(:prompts, publish.prompts)

    quote generated: true,
          bind_quoted: [
            name: name,
            version: version,
            tools: publish.tools,
            resources: publish.resources,
            prompts: publish.prompts,
            capability_names: Map.keys(capabilities)
          ] do
      alias ExMCP.Protocol.Initialize
      alias ExMCP.Server.{Handler, HandlerServer, Transport}
      alias Jido.MCP.Server.Runtime

      use Handler

      @publish_tools tools
      @publish_resources resources
      @publish_prompts prompts
      @server_info %{name: name, version: version}
      @server_capabilities Map.new(capability_names, &{&1, %{}})

      @doc false
      def __publish__,
        do: %{tools: @publish_tools, resources: @publish_resources, prompts: @publish_prompts}

      @doc false
      def __server_info__, do: @server_info

      @doc false
      def __server_capabilities__, do: @server_capabilities

      @doc "Starts the allowlisted MCP server with an ExMCP transport."
      def start_link(opts \\ []) do
        case Keyword.get(opts, :transport, :stdio) do
          transport when transport in [:beam, :test] ->
            opts
            |> Keyword.put(:transport, transport)
            |> Keyword.put_new(:handler, __MODULE__)
            |> HandlerServer.start_link()

          :streamable_http ->
            Transport.start_server(
              __MODULE__,
              @server_info,
              [],
              Keyword.put(opts, :transport, :http)
            )

          transport when transport in [:http, :stdio] ->
            Transport.start_server(__MODULE__, @server_info, [], opts)

          transport ->
            {:error, {:unsupported_transport, transport}}
        end
      end

      @impl GenServer
      def init(args), do: {:ok, Runtime.init_state(args)}

      @impl ExMCP.Server.Handler
      def handle_initialize(params, state) do
        result =
          Initialize.build_initialize_result(params, %{
            serverInfo: @server_info,
            capabilities: @server_capabilities
          })

        {:ok, result, state}
      end

      @impl ExMCP.Server.Handler
      def handle_list_tools(_cursor, state),
        do: Runtime.list_tools(@publish_tools, state)

      @impl ExMCP.Server.Handler
      def handle_call_tool(name, arguments, state) do
        Runtime.handle_tool_call(
          @publish_tools,
          name,
          arguments,
          state,
          __MODULE__
        )
      end

      @impl ExMCP.Server.Handler
      def handle_list_resources(_cursor, state),
        do: Runtime.list_resources(@publish_resources, state)

      @impl ExMCP.Server.Handler
      def handle_read_resource(uri, state) do
        Runtime.handle_resource_read(
          @publish_resources,
          uri,
          state,
          __MODULE__
        )
      end

      @impl ExMCP.Server.Handler
      def handle_list_prompts(_cursor, state),
        do: Runtime.list_prompts(@publish_prompts, state)

      @impl ExMCP.Server.Handler
      def handle_get_prompt(name, arguments, state) do
        Runtime.handle_prompt_get(
          @publish_prompts,
          name,
          arguments,
          state,
          __MODULE__
        )
      end

      @doc """
      Optional authorization callback.

      Return `:ok` or `true` to allow the request. Return any other value to
      deny the request.
      """
      @spec authorize(map(), Jido.MCP.Server.Context.t()) :: :ok | true | term()
      def authorize(_request, _context), do: :ok

      defoverridable authorize: 2
    end
  end

  defp maybe_capability(capabilities, _name, []), do: capabilities
  defp maybe_capability(capabilities, name, _entries), do: Map.put(capabilities, name, %{})
end
