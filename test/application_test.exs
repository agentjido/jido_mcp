defmodule Jido.MCP.ApplicationTest do
  use ExUnit.Case, async: true

  test "starts the managed Finch pool" do
    assert Process.whereis(Jido.MCP.Finch)
  end
end
