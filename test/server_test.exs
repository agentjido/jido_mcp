defmodule Jido.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Jido.MCP.Server

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
    assert is_list(children)
    assert length(children) == 2
    assert Server.plug_init_opts(DemoServer) == [server: DemoServer]
  end

  test "use macro publishes explicit allowlist and registers components on init" do
    assert %{tools: [DemoAction], resources: [DemoResource], prompts: [DemoPrompt]} =
             DemoServer.__publish__()

    assert {:ok, frame} = DemoServer.init(%{}, Frame.new())
    assert length(Frame.get_tools(frame)) == 1
    assert length(Frame.get_resources(frame)) == 1
    assert length(Frame.get_prompts(frame)) == 1
  end

  test "default authorize callback allows requests" do
    assert :ok = DemoServer.authorize(%{type: :tool_call}, Frame.new())
  end
end
