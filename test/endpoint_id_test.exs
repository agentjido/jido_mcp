defmodule Jido.MCP.EndpointIDTest do
  use ExUnit.Case, async: true

  alias Jido.MCP.EndpointID

  @endpoints %{
    github: %{id: :github},
    filesystem: %{id: :filesystem}
  }

  test "resolves known atom endpoint ids" do
    assert {:ok, :github} = EndpointID.resolve(:github, @endpoints)
  end

  test "resolves known string endpoint ids" do
    assert {:ok, :filesystem} = EndpointID.resolve("filesystem", @endpoints)
    assert {:ok, :github} = EndpointID.resolve(" github ", @endpoints)
  end

  test "keeps runtime string endpoint ids as strings" do
    endpoints = Map.put(@endpoints, "runtime-47", %{id: "runtime-47"})

    assert {:ok, "runtime-47"} = EndpointID.resolve("runtime-47", endpoints)
    assert {:ok, "runtime-47"} = EndpointID.resolve(:"runtime-47", endpoints)
  end

  test "rejects unknown endpoint ids" do
    assert {:error, :unknown_endpoint} = EndpointID.resolve(:missing, @endpoints)
    assert {:error, :unknown_endpoint} = EndpointID.resolve("missing", @endpoints)
  end

  test "rejects missing or invalid endpoint ids" do
    assert {:error, :endpoint_required} = EndpointID.resolve(nil, @endpoints)
    assert {:error, :invalid_endpoint_id} = EndpointID.resolve("", @endpoints)
    assert {:error, :invalid_endpoint_id} = EndpointID.resolve(%{}, @endpoints)
    assert {:error, :invalid_endpoint_id} = EndpointID.resolve("bad\0id", @endpoints)

    assert {:error, :invalid_endpoint_id} =
             EndpointID.resolve(String.duplicate("a", 256), @endpoints)

    assert {:error, :invalid_endpoint_id} = EndpointID.resolve(<<255>>, @endpoints)
  end
end
