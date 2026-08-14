defmodule Jido.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias Jido.MCP.ExMCPClient
  alias Jido.MCP.Server
  alias Jido.MCP.Server.Context

  defmodule DemoAction do
    use Jido.Action,
      name: "demo_action",
      description: "Demo action",
      schema: []

    @impl true
    def run(_params, _context), do: {:ok, %{ok: true}}
  end

  defmodule DemoResource do
    @behaviour Jido.MCP.Server.Resource

    @impl true
    def uri, do: "memo://demo"

    @impl true
    def name, do: "demo_resource"

    @impl true
    def description, do: "Demo resource"

    @impl true
    def mime_type, do: "application/json"

    @impl true
    def read(_uri, _frame), do: {:ok, %{ok: true}}
  end

  defmodule DemoPrompt do
    @behaviour Jido.MCP.Server.Prompt

    @impl true
    def name, do: "demo_prompt"

    @impl true
    def description, do: "Demo prompt"

    @impl true
    def arguments_schema, do: %{topic: {:required, :string}}

    @impl true
    def messages(_arguments, _frame), do: {:ok, [%{"role" => "user", "content" => "hello"}]}
  end

  defmodule DemoServer do
    use Jido.MCP.Server,
      name: "demo-server",
      version: "1.0.0",
      publish: %{
        tools: [Jido.MCP.ServerTest.DemoAction],
        resources: [Jido.MCP.ServerTest.DemoResource],
        prompts: [Jido.MCP.ServerTest.DemoPrompt]
      }
  end

  test "server_children and plug_init_opts return integration helpers" do
    children = Server.server_children(DemoServer, transport: :streamable_http)
    assert children == [{DemoServer, [transport: :streamable_http]}]

    assert Server.plug_init_opts(DemoServer) ==
             [handler: DemoServer, server_info: %{name: "demo-server", version: "1.0.0"}]
  end

  test "use macro publishes explicit allowlist and ExMCP definitions" do
    assert %{tools: [DemoAction], resources: [DemoResource], prompts: [DemoPrompt]} =
             DemoServer.__publish__()

    assert {:ok, state} = DemoServer.init([])
    assert {:ok, [_tool], nil, ^state} = DemoServer.handle_list_tools(nil, state)
    assert {:ok, [_resource], nil, ^state} = DemoServer.handle_list_resources(nil, state)
    assert {:ok, [_prompt], nil, ^state} = DemoServer.handle_list_prompts(nil, state)
  end

  test "default authorize callback allows requests" do
    assert :ok = DemoServer.authorize(%{type: :tool_call}, %Context{})
  end

  test "serves the allowlist through an ExMCP BEAM connection" do
    server = start_supervised!({DemoServer, transport: :beam})

    client =
      start_supervised!(
        {ExMCP.Client,
         transport: :beam,
         server: server,
         protocol_version: "2025-06-18",
         protocol_mode: :legacy_only,
         reconnect: false,
         retry_policy: []}
      )

    assert {:ok, %{"tools" => [%{"name" => "demo_action"}]}} =
             ExMCPClient.list_tools(client, [])

    assert {:ok, %{"structuredContent" => %{"ok" => true}}} =
             ExMCPClient.call_tool(client, "demo_action", %{}, [])

    assert {:ok, %{"contents" => [%{"uri" => "memo://demo"}]}} =
             ExMCPClient.read_resource(client, "memo://demo", [])

    assert {:ok, %{"messages" => [%{"role" => "user"}]}} =
             ExMCPClient.get_prompt(client, "demo_prompt", %{}, [])
  end
end
