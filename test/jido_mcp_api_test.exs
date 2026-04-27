defmodule Jido.MCP.APITest do
  use ExUnit.Case, async: false
  use Mimic

  alias Anubis.MCP.Response, as: MCPResponse

  setup :set_mimic_from_context

  test "list_tools preserves caller opts and applies default timeout" do
    endpoint = %{timeouts: %{request_ms: 321}}
    ref = %{client: :mock_client}

    Mimic.expect(Jido.MCP.ClientPool, :ensure_client, fn :github ->
      {:ok, endpoint, ref}
    end)

    Mimic.expect(Jido.MCP.ClientPool, :await_ready, fn ^ref, 321 ->
      :ok
    end)

    Mimic.expect(Anubis.Client, :list_tools, fn :mock_client, opts ->
      assert opts[:cursor] == "abc123"
      assert opts[:timeout] == 321
      {:ok, MCPResponse.from_json_rpc(%{"id" => "1", "result" => %{"tools" => []}})}
    end)

    assert {:ok, result} = Jido.MCP.list_tools(:github, cursor: "abc123")
    assert result.method == "tools/list"
    assert result.data == %{"tools" => []}
  end

  test "list_tools preserves explicit timeout and uses explicit readiness timeout" do
    endpoint = %{timeouts: %{request_ms: 321}}
    ref = %{client: :mock_client}

    Mimic.expect(Jido.MCP.ClientPool, :ensure_client, fn :github ->
      {:ok, endpoint, ref}
    end)

    Mimic.expect(Jido.MCP.ClientPool, :await_ready, fn ^ref, 123 ->
      :ok
    end)

    Mimic.expect(Anubis.Client, :list_tools, fn :mock_client, opts ->
      assert opts[:timeout] == 999
      refute Keyword.has_key?(opts, :ready_timeout)
      {:ok, MCPResponse.from_json_rpc(%{"id" => "1", "result" => %{"tools" => []}})}
    end)

    assert {:ok, _result} = Jido.MCP.list_tools(:github, timeout: 999, ready_timeout: 123)
  end

  test "refresh_endpoint refreshes client lifecycle" do
    endpoint = %{timeouts: %{request_ms: 444}}
    ref = %{client: :mock_client}

    Mimic.expect(Jido.MCP.ClientPool, :refresh, fn :github ->
      {:ok, endpoint, ref}
    end)

    assert {:ok, ^endpoint, ^ref} = Jido.MCP.refresh_endpoint(:github)
  end
end
