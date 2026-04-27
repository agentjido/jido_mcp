defmodule Jido.MCPTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Anubis.MCP.Response, as: MCPResponse
  alias Jido.MCP

  setup :set_mimic_private
  setup :verify_on_exit!

  setup do
    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:github, %{
        transport: {:stdio, [command: "cat", args: []]},
        client_info: %{name: "test"},
        timeouts: %{request_ms: 7_500}
      })

    stub(Jido.MCP.ClientPool, :ensure_client, fn :github ->
      {:ok, endpoint,
       %{client: :demo_client, supervisor: :demo_supervisor, transport: :demo_transport}}
    end)

    stub(Jido.MCP.ClientPool, :await_ready, fn %{client: :demo_client}, _timeout ->
      :ok
    end)

    %{endpoint: endpoint}
  end

  test "list tools forwards cursor and timeout" do
    raw = MCPResponse.from_json_rpc(%{"id" => "1", "result" => %{"tools" => []}})

    expect(Anubis.Client, :list_tools, fn :demo_client, opts ->
      assert opts[:cursor] == "next"
      assert opts[:timeout] == 1_200
      {:ok, raw}
    end)

    assert {:ok, %{data: %{"tools" => []}}} =
             MCP.list_tools(:github, cursor: "next", timeout: 1_200)
  end

  test "list resources forwards cursor and timeout" do
    raw = MCPResponse.from_json_rpc(%{"id" => "1", "result" => %{"resources" => []}})

    expect(Anubis.Client, :list_resources, fn :demo_client, opts ->
      assert opts[:cursor] == "c1"
      assert opts[:timeout] == 800
      {:ok, raw}
    end)

    assert {:ok, %{data: %{"resources" => []}}} =
             MCP.list_resources(:github, cursor: "c1", timeout: 800)
  end

  test "list resource templates forwards cursor and timeout" do
    raw = MCPResponse.from_json_rpc(%{"id" => "1", "result" => %{"resourceTemplates" => []}})

    expect(Anubis.Client, :list_resource_templates, fn :demo_client, opts ->
      assert opts[:cursor] == "c2"
      assert opts[:timeout] == 900
      {:ok, raw}
    end)

    assert {:ok, %{data: %{"resourceTemplates" => []}}} =
             MCP.list_resource_templates(:github, cursor: "c2", timeout: 900)
  end

  test "list prompts forwards cursor and timeout" do
    raw = MCPResponse.from_json_rpc(%{"id" => "1", "result" => %{"prompts" => []}})

    expect(Anubis.Client, :list_prompts, fn :demo_client, opts ->
      assert opts[:cursor] == "p1"
      assert opts[:timeout] == 1_100
      {:ok, raw}
    end)

    assert {:ok, %{data: %{"prompts" => []}}} =
             MCP.list_prompts(:github, cursor: "p1", timeout: 1_100)
  end

  test "call_tool, read_resource, and get_prompt pass through arguments" do
    ok_raw = MCPResponse.from_json_rpc(%{"id" => "1", "result" => %{}})

    expect(Anubis.Client, :call_tool, fn :demo_client, "search", %{"q" => "bug"}, opts ->
      assert opts[:timeout] == 2_000
      {:ok, ok_raw}
    end)

    expect(Anubis.Client, :read_resource, fn :demo_client, "repo://README", opts ->
      assert opts[:timeout] == 2_100
      {:ok, ok_raw}
    end)

    expect(Anubis.Client, :get_prompt, fn :demo_client, "release", %{"v" => "1.0.0"}, opts ->
      assert opts[:timeout] == 2_200
      {:ok, ok_raw}
    end)

    assert {:ok, _} = MCP.call_tool(:github, "search", %{"q" => "bug"}, timeout: 2_000)
    assert {:ok, _} = MCP.read_resource(:github, "repo://README", timeout: 2_100)
    assert {:ok, _} = MCP.get_prompt(:github, "release", %{"v" => "1.0.0"}, timeout: 2_200)
  end

  test "uses endpoint default timeout when one is not provided", %{endpoint: endpoint} do
    raw = MCPResponse.from_json_rpc(%{"id" => "1", "result" => %{"tools" => []}})

    expect(Anubis.Client, :list_tools, fn :demo_client, opts ->
      assert opts[:timeout] == endpoint.timeouts.request_ms
      {:ok, raw}
    end)

    assert {:ok, _} = MCP.list_tools(:github)
  end

  test "refresh_endpoint refreshes then lists tools" do
    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:github, %{
        transport: {:stdio, [command: "cat", args: []]},
        client_info: %{name: "test"},
        timeouts: %{request_ms: 444}
      })

    expect(Jido.MCP.ClientPool, :refresh, fn :github ->
      {:ok, endpoint,
       %{client: :demo_client, supervisor: :demo_supervisor, transport: :demo_transport}}
    end)

    expect(Jido.MCP.ClientPool, :ensure_client, fn :github ->
      {:ok, endpoint,
       %{client: :demo_client, supervisor: :demo_supervisor, transport: :demo_transport}}
    end)

    raw = MCPResponse.from_json_rpc(%{"id" => "1", "result" => %{"tools" => []}})

    expect(Anubis.Client, :list_tools, fn :demo_client, opts ->
      assert opts[:timeout] == 444
      {:ok, raw}
    end)

    assert {:ok, result} = MCP.refresh_endpoint(:github)
    assert result.method == "tools/list"
    assert result.data == %{"tools" => []}
  end

  test "endpoint_status passthrough" do
    expect(Jido.MCP.ClientPool, :endpoint_status, fn :github ->
      {:ok, %{endpoint_id: :github, client_alive?: true}}
    end)

    assert {:ok, %{endpoint_id: :github}} = MCP.endpoint_status(:github)
  end

  test "register_endpoint delegates to client pool" do
    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:runtime, %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "test"}
      })

    expect(Jido.MCP.ClientPool, :register_endpoint, fn ^endpoint ->
      {:ok, endpoint}
    end)

    assert {:ok, ^endpoint} = MCP.register_endpoint(endpoint)
  end

  test "register_endpoint propagates client pool errors" do
    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:github, %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "test"}
      })

    expect(Jido.MCP.ClientPool, :register_endpoint, fn ^endpoint ->
      {:error, {:endpoint_already_registered, :github}}
    end)

    assert {:error, {:endpoint_already_registered, :github}} = MCP.register_endpoint(endpoint)
  end

  test "returns client pool errors" do
    expect(Jido.MCP.ClientPool, :ensure_client, fn :github ->
      {:error, :unknown_endpoint}
    end)

    assert {:error, :unknown_endpoint} = MCP.list_tools(:github)
  end

  test "refresh_endpoint propagates client pool errors" do
    expect(Jido.MCP.ClientPool, :refresh, fn :github ->
      {:error, :unknown_endpoint}
    end)

    assert {:error, :unknown_endpoint} = MCP.refresh_endpoint(:github)
  end

  test "refresh_endpoint propagates list errors" do
    {:ok, endpoint} =
      Jido.MCP.Endpoint.new(:github, %{
        transport: {:stdio, [command: "cat", args: []]},
        client_info: %{name: "test"},
        timeouts: %{request_ms: 444}
      })

    expect(Jido.MCP.ClientPool, :refresh, fn :github ->
      {:ok, endpoint,
       %{client: :demo_client, supervisor: :demo_supervisor, transport: :demo_transport}}
    end)

    expect(Jido.MCP.ClientPool, :ensure_client, fn :github ->
      {:ok, endpoint,
       %{client: :demo_client, supervisor: :demo_supervisor, transport: :demo_transport}}
    end)

    expect(Anubis.Client, :list_tools, fn :demo_client, opts ->
      assert opts[:timeout] == 444
      {:error, :not_started}
    end)

    assert {:error, %{status: :error, type: :transport, details: :not_started}} =
             MCP.refresh_endpoint(:github)
  end
end
