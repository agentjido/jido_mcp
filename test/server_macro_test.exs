defmodule Jido.MCP.ServerMacroTest do
  use ExUnit.Case, async: true

  alias Jido.MCP.Server

  defmodule DemoAction do
    use Jido.Action,
      name: "ping",
      schema: Zoi.object(%{value: Zoi.string()})

    @impl true
    def run(%{value: value}, _context), do: {:ok, %{pong: value}}
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
    def arguments_schema, do: %{}

    @impl true
    def messages(_arguments, _frame), do: {:ok, [%{"role" => "user", "content" => "hello"}]}
  end

  defmodule DemoServer do
    use Jido.MCP.Server,
      name: "demo",
      version: "1.0.0",
      publish: %{
        tools: [Jido.MCP.ServerMacroTest.DemoAction],
        resources: [Jido.MCP.ServerMacroTest.DemoResource],
        prompts: [Jido.MCP.ServerMacroTest.DemoPrompt]
      }
  end

  test "builds server children and plug opts" do
    children = Server.server_children(DemoServer, transport: :streamable_http)

    assert {DemoServer, [transport: :streamable_http]} in children

    assert [handler: DemoServer, server_info: %{name: "demo", version: "1.0.0"}] ==
             Server.plug_init_opts(DemoServer)

    assert {DemoServer, [transport: :stdio]} in Server.server_children(DemoServer)
  end

  test "macro-published server handles tools/resources/prompts" do
    assert %{tools: [_], resources: [_], prompts: [_]} = DemoServer.__publish__()

    assert {:ok, state} = DemoServer.init([])

    assert {:ok, response, ^state} =
             DemoServer.handle_call_tool("ping", %{value: "ok"}, state)

    assert response.structuredContent == %{pong: "ok"}

    assert {:ok, resource_response, ^state} =
             DemoServer.handle_read_resource("memo://demo", state)

    assert resource_response.uri == "memo://demo"

    assert {:ok, prompt_response, ^state} =
             DemoServer.handle_get_prompt("demo_prompt", %{}, state)

    assert length(prompt_response.messages) == 1
  end

  test "raises when publish option does not evaluate to a map" do
    assert_raise ArgumentError, ~r/publish must evaluate to a map/, fn ->
      defmodule InvalidServer do
        use Jido.MCP.Server,
          name: "invalid",
          version: "1.0.0",
          publish: :invalid
      end
    end
  end
end
