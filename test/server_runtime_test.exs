defmodule Jido.MCP.Server.RuntimeTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Jido.MCP.Server.Runtime

  defmodule AddAction do
    use Jido.Action,
      name: "add",
      schema: [
        a: [type: :integer, required: true],
        b: [type: :integer, required: true]
      ]

    @impl true
    def run(%{a: a, b: b}, _context), do: {:ok, %{sum: a + b}}
  end

  defmodule EchoResource do
    @behaviour Jido.MCP.Server.Resource

    @impl true
    def uri, do: "memo://echo"

    @impl true
    def name, do: "echo_resource"

    @impl true
    def description, do: "Echo resource"

    @impl true
    def mime_type, do: "application/json"

    @impl true
    def read(_uri, _frame), do: {:ok, %{ok: true}}
  end

  defmodule BasicPrompt do
    @behaviour Jido.MCP.Server.Prompt

    @impl true
    def name, do: "basic_prompt"

    @impl true
    def description, do: "Basic prompt"

    @impl true
    def arguments_schema, do: %{topic: {:required, :string}}

    @impl true
    def messages(args, _frame),
      do: {:ok, [%{"role" => "user", "content" => "Topic: #{args["topic"]}"}]}
  end

  defmodule AllowAllServer do
    def authorize(_request, _frame), do: :ok
  end

  defmodule RaisingAuthServer do
    def authorize(_request, _frame), do: raise("boom")
  end

  defmodule BrokenResource do
    @behaviour Jido.MCP.Server.Resource

    @impl true
    def uri, do: "memo://broken"

    @impl true
    def name, do: "broken_resource"

    @impl true
    def description, do: "Broken resource"

    @impl true
    def mime_type, do: "application/json"

    @impl true
    def read(_uri, _frame), do: :not_a_tuple
  end

  defmodule BrokenPrompt do
    @behaviour Jido.MCP.Server.Prompt

    @impl true
    def name, do: "broken_prompt"

    @impl true
    def description, do: "Broken prompt"

    @impl true
    def arguments_schema, do: %{}

    @impl true
    def messages(_arguments, _frame), do: :not_a_tuple
  end

  test "handles tool call through Jido action" do
    frame = Frame.new()

    assert {:reply, response, _frame} =
             Runtime.handle_tool_call([AddAction], "add", %{a: 2, b: 5}, frame, AllowAllServer)

    assert response.type == :tool
    assert response.structured_content == %{sum: 7}
  end

  test "handles resource read" do
    frame = Frame.new()

    assert {:reply, response, _frame} =
             Runtime.handle_resource_read(
               [EchoResource],
               EchoResource.uri(),
               frame,
               AllowAllServer
             )

    assert response.type == :resource
    assert response.contents["text"]
  end

  test "handles prompt get" do
    frame = Frame.new()

    assert {:reply, response, _frame} =
             Runtime.handle_prompt_get(
               [BasicPrompt],
               "basic_prompt",
               %{"topic" => "mcp"},
               frame,
               AllowAllServer
             )

    assert response.type == :prompt
    assert length(response.messages) == 1
  end

  test "register_tool publishes strict json schema from action schema" do
    frame = Frame.new() |> Runtime.register_tool(AddAction)

    [tool] = Frame.get_tools(frame)
    assert tool.name == "add"
    assert is_map(tool.input_schema)
    assert tool.input_schema["type"]
    rendered = inspect(tool.input_schema)
    assert rendered =~ "\"a\""
    assert rendered =~ "\"b\""
  end

  test "fails closed when authorization callback raises" do
    frame = Frame.new()

    assert {:error, error, _frame} =
             Runtime.handle_tool_call([AddAction], "add", %{a: 1, b: 2}, frame, RaisingAuthServer)

    assert error.code == -32600
  end

  test "returns deterministic execution errors for invalid resource handler output" do
    frame = Frame.new()

    assert {:error, error, _frame} =
             Runtime.handle_resource_read(
               [BrokenResource],
               BrokenResource.uri(),
               frame,
               AllowAllServer
             )

    assert error.code == -32000
  end

  test "returns deterministic execution errors for invalid prompt handler output" do
    frame = Frame.new()

    assert {:error, error, _frame} =
             Runtime.handle_prompt_get(
               [BrokenPrompt],
               "broken_prompt",
               %{},
               frame,
               AllowAllServer
             )

    assert error.code == -32000
  end
end
