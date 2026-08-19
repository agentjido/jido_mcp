defmodule Jido.MCP.Server.RuntimeTest do
  use ExUnit.Case, async: true

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

  defmodule ContextAction do
    use Jido.Action,
      name: "context",
      schema: []

    @impl true
    def run(_params, context) do
      {:ok,
       %{
         assigns: context.assigns,
         frame_assigns: context.mcp_frame.assigns,
         mcp_context_is_nil: is_nil(context.mcp_context),
         request_is_nil: is_nil(context.request),
         transport: context.transport
       }}
    end
  end

  defmodule FailureEnvelopeAction do
    use Jido.Action,
      name: "failure_envelope",
      schema: []

    @impl true
    def run(_params, _context) do
      {:ok, %{ok: false, error: %{code: :action_not_allowed, message: "Access is denied."}}}
    end
  end

  defmodule OpenInputAction do
    use Jido.Action,
      name: "open_input",
      description: "Accepts a provider-owned input object",
      schema: %{
        "type" => "object",
        "properties" => %{
          "input" => %{
            "type" => "object",
            "properties" => %{
              "provider_field" => %{"type" => "string"}
            }
          }
        },
        "required" => ["input"]
      }

    @impl true
    def run(_params, _context), do: {:ok, %{ok: true}}
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
    state = %{assigns: %{}}

    assert {:ok, response, ^state} =
             Runtime.handle_tool_call([AddAction], "add", %{a: 2, b: 5}, state, AllowAllServer)

    assert response.structuredContent == %{sum: 7}
  end

  test "builds action context from the server state" do
    state = %{assigns: %{tenant: "zaq"}}

    assert {:ok, response, ^state} =
             Runtime.handle_tool_call([ContextAction], "context", %{}, state, AllowAllServer)

    assert response.structuredContent == %{
             assigns: %{tenant: "zaq"},
             frame_assigns: %{tenant: "zaq"},
             mcp_context_is_nil: true,
             request_is_nil: true,
             transport: %{}
           }
  end

  test "marks a structured failure envelope as an MCP tool error" do
    state = %{assigns: %{}}

    assert {:ok, response, ^state} =
             Runtime.handle_tool_call(
               [FailureEnvelopeAction],
               "failure_envelope",
               %{},
               state,
               AllowAllServer
             )

    assert response.structuredContent == %{
             ok: false,
             error: %{code: :action_not_allowed, message: "Access is denied."}
           }

    assert [%{type: "text", text: text}] = response.content

    assert Jason.decode!(text) == %{
             "ok" => false,
             "error" => %{"code" => "action_not_allowed", "message" => "Access is denied."}
           }

    assert response.isError == true
  end

  test "loads a published action before a direct tool call" do
    action = Jido.MCP.Actions.ListTools
    :code.purge(action)
    :code.delete(action)
    refute Code.loaded?(action)

    state = %{assigns: %{}}

    assert {:ok, %{isError: true}, ^state} =
             Runtime.handle_tool_call(
               [action],
               "mcp_tools_list",
               %{},
               state,
               AllowAllServer
             )

    assert Code.loaded?(action)
  end

  test "handles resource read" do
    state = %{assigns: %{}}

    assert {:ok, response, ^state} =
             Runtime.handle_resource_read(
               [EchoResource],
               EchoResource.uri(),
               state,
               AllowAllServer
             )

    assert response.uri == EchoResource.uri()
    assert response.text
  end

  test "handles prompt get" do
    state = %{assigns: %{}}

    assert {:ok, response, ^state} =
             Runtime.handle_prompt_get(
               [BasicPrompt],
               "basic_prompt",
               %{"topic" => "mcp"},
               state,
               AllowAllServer
             )

    assert length(response.messages) == 1
  end

  test "register_tool publishes strict json schema from action schema" do
    assert {:ok, [tool], nil, _state} = Runtime.list_tools([AddAction], %{})
    assert tool.name == "add"
    assert is_map(tool.inputSchema)
    assert tool.inputSchema["type"]
    rendered = inspect(tool.inputSchema)
    assert rendered =~ "\"a\""
    assert rendered =~ "\"b\""
  end

  test "keeps an explicit nested JSON Schema object open while the tool input stays strict" do
    assert {:ok, [tool], nil, _state} = Runtime.list_tools([OpenInputAction], %{})

    assert tool.inputSchema["additionalProperties"] == false

    refute Map.has_key?(
             tool.inputSchema["properties"]["input"],
             "additionalProperties"
           )
  end

  test "fails closed when authorization callback raises" do
    state = %{assigns: %{}}

    assert {:error, error, ^state} =
             Runtime.handle_tool_call([AddAction], "add", %{a: 1, b: 2}, state, RaisingAuthServer)

    assert error.code == -32_600
  end

  test "returns deterministic execution errors for invalid resource handler output" do
    state = %{assigns: %{}}

    assert {:error, error, ^state} =
             Runtime.handle_resource_read(
               [BrokenResource],
               BrokenResource.uri(),
               state,
               AllowAllServer
             )

    assert error.code == -32_000
  end

  test "returns deterministic execution errors for invalid prompt handler output" do
    state = %{assigns: %{}}

    assert {:error, error, ^state} =
             Runtime.handle_prompt_get(
               [BrokenPrompt],
               "broken_prompt",
               %{},
               state,
               AllowAllServer
             )

    assert error.code == -32_000
  end
end
