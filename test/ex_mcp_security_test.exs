defmodule Jido.MCP.ExMCPSecurityTest do
  use ExUnit.Case, async: true

  import Plug.Test

  test "Plug rejects response header bytes covered by EEF-CVE-2026-43966" do
    conn = conn(:get, "/")

    for invalid <- ["safe\r\nx-injected: true", "safe\n", <<"safe", 0>>] do
      assert_raise Plug.Conn.InvalidHeaderError, fn ->
        Plug.Conn.put_resp_header(conn, "x-test", invalid)
      end
    end
  end

  test "ExMCP does not import the encoders from the acknowledged Cowlib advisories" do
    {:ok, modules} = :application.get_key(:ex_mcp, :modules)

    imports =
      Enum.flat_map(modules, fn module ->
        {:module, ^module} = Code.ensure_loaded(module)

        case :code.which(module) do
          path when is_list(path) -> imports(path)
          _not_loaded -> []
        end
      end)

    refute {:cow_cookie, :cookie, 1} in imports
    refute {:cow_link, :link, 1} in imports
  end

  defp imports(path) do
    case :beam_lib.chunks(path, [:imports]) do
      {:ok, {_module, [{:imports, module_imports}]}} -> module_imports
      _unavailable -> []
    end
  end
end
