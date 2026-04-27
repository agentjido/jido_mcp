defmodule Jido.MCP.ActionsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Jido.MCP.Actions.{
    CallTool,
    GetPrompt,
    ListPrompts,
    ListResourceTemplates,
    ListResources,
    ListTools,
    ReadResource,
    RefreshEndpoint
  }

  alias Jido.MCP.{ClientPool, Config}

  setup :set_mimic_from_context

  setup do
    previous = Application.get_env(:jido_mcp, :endpoints)

    Application.put_env(:jido_mcp, :endpoints, %{
      github: %{
        transport: {:streamable_http, [base_url: "http://localhost:3000/mcp"]},
        client_info: %{name: "my_app"}
      },
      filesystem: %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      }
    })

    load_pool_from_config()

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:jido_mcp, :endpoints)
      else
        Application.put_env(:jido_mcp, :endpoints, previous)
      end

      load_pool_from_config()
    end)

    :ok
  end

  test "list tools/resources/prompts actions pass through timeout and cursor" do
    Mimic.expect(Jido.MCP, :list_tools, fn :github, opts ->
      assert opts[:timeout] == 111
      assert opts[:cursor] == "abc"
      {:ok, %{status: :ok}}
    end)

    Mimic.expect(Jido.MCP, :list_resources, fn :github, opts ->
      assert opts[:timeout] == 222
      assert opts[:cursor] == "def"
      {:ok, %{status: :ok}}
    end)

    Mimic.expect(Jido.MCP, :list_resource_templates, fn :github, opts ->
      assert opts[:timeout] == 333
      assert opts[:cursor] == "ghi"
      {:ok, %{status: :ok}}
    end)

    Mimic.expect(Jido.MCP, :list_prompts, fn :github, opts ->
      assert opts[:timeout] == 444
      assert opts[:cursor] == "jkl"
      {:ok, %{status: :ok}}
    end)

    context = %{allowed_endpoints: [:github]}

    assert {:ok, %{status: :ok}} =
             ListTools.run(%{endpoint_id: "github", timeout: 111, cursor: "abc"}, context)

    assert {:ok, %{status: :ok}} =
             ListResources.run(%{endpoint_id: :github, timeout: 222, cursor: "def"}, context)

    assert {:ok, %{status: :ok}} =
             ListResourceTemplates.run(
               %{endpoint_id: :github, timeout: 333, cursor: "ghi"},
               context
             )

    assert {:ok, %{status: :ok}} =
             ListPrompts.run(%{endpoint_id: :github, timeout: 444, cursor: "jkl"}, context)
  end

  test "call/read/get/refresh actions call corresponding API functions" do
    Mimic.expect(Jido.MCP, :call_tool, fn :github, "search", %{"q" => "bug"}, opts ->
      assert opts[:timeout] == 500
      {:ok, %{status: :ok, kind: :call_tool}}
    end)

    Mimic.expect(Jido.MCP, :read_resource, fn :github, "memo://x", opts ->
      assert opts[:timeout] == 600
      {:ok, %{status: :ok, kind: :read_resource}}
    end)

    Mimic.expect(Jido.MCP, :get_prompt, fn :github,
                                           "release_notes",
                                           %{"version" => "1.0.0"},
                                           opts ->
      assert opts[:timeout] == 700
      {:ok, %{status: :ok, kind: :get_prompt}}
    end)

    Mimic.expect(Jido.MCP, :refresh_endpoint, fn :github ->
      {:ok, %{status: :ok, kind: :refresh}}
    end)

    context = %{allowed_endpoints: [:github]}

    assert {:ok, %{kind: :call_tool}} =
             CallTool.run(
               %{
                 endpoint_id: :github,
                 tool_name: "search",
                 arguments: %{"q" => "bug"},
                 timeout: 500
               },
               context
             )

    assert {:ok, %{kind: :read_resource}} =
             ReadResource.run(%{endpoint_id: :github, uri: "memo://x", timeout: 600}, context)

    assert {:ok, %{kind: :get_prompt}} =
             GetPrompt.run(
               %{
                 endpoint_id: :github,
                 prompt_name: "release_notes",
                 arguments: %{"version" => "1.0.0"},
                 timeout: 700
               },
               context
             )

    assert {:ok, %{kind: :refresh}} =
             RefreshEndpoint.run(%{endpoint_id: "github"}, context)
  end

  test "actions fail closed when endpoint is not allowlisted" do
    context = %{allowed_endpoints: [:github]}

    assert {:error, :endpoint_not_allowed} =
             ListTools.run(%{endpoint_id: :filesystem}, context)
  end

  test "actions resolve runtime-registered endpoints" do
    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:runtime, %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      })

    assert {:ok, ^endpoint} = ClientPool.register_endpoint(endpoint)

    Mimic.expect(Jido.MCP, :list_tools, fn :runtime, _opts ->
      {:ok, %{status: :ok, endpoint: :runtime}}
    end)

    assert {:ok, %{endpoint: :runtime}} =
             ListTools.run(%{endpoint_id: "runtime"}, %{allowed_endpoints: [:runtime]})
  end

  defp load_pool_from_config do
    :sys.replace_state(ClientPool, fn state ->
      %{state | endpoints: Config.endpoints(), refs: %{}}
    end)
  end
end
