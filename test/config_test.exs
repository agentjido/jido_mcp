defmodule Jido.MCP.ConfigTest do
  use ExUnit.Case, async: false

  alias Jido.MCP.Config

  defmodule EndpointSource do
    def map_endpoints do
      %{
        runtime: %{
          transport: {:stdio, [command: "echo"]},
          client_info: %{name: "my_app"}
        }
      }
    end

    def ok_keyword_endpoints do
      {:ok,
       [
         runtime: %{
           transport: {:stdio, [command: "echo"]},
           client_info: %{name: "my_app"}
         }
       ]}
    end

    def invalid_endpoints, do: {:error, :boom}
  end

  setup do
    previous = Application.get_env(:jido_mcp, :endpoints)

    Application.put_env(:jido_mcp, :endpoints, %{
      github: %{
        transport: {:streamable_http, [base_url: "http://localhost:3000/mcp"]},
        client_info: %{name: "my_app"}
      }
    })

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:jido_mcp, :endpoints)
      else
        Application.put_env(:jido_mcp, :endpoints, previous)
      end
    end)

    :ok
  end

  test "resolve_endpoint_id supports known atoms and strings only" do
    assert {:ok, :github} = Config.resolve_endpoint_id(:github)
    assert {:ok, :github} = Config.resolve_endpoint_id("github")
    assert {:ok, _endpoint} = Config.fetch_endpoint(:github)
    assert {:error, :unknown_endpoint} = Config.resolve_endpoint_id(:missing)
    assert {:error, :unknown_endpoint} = Config.resolve_endpoint_id("missing")
    assert {:error, :unknown_endpoint} = Config.fetch_endpoint(:missing)
    assert {:error, :endpoint_required} = Config.resolve_endpoint_id(nil)
  end

  test "normalize_endpoints rejects binary endpoint ids" do
    assert_raise ArgumentError, ~r/endpoint keys must be atoms/, fn ->
      Config.normalize_endpoints(%{
        "github" => %{
          transport: {:streamable_http, [base_url: "http://localhost:3000/mcp"]},
          client_info: %{name: "my_app"}
        }
      })
    end
  end

  test "loads endpoint config from keyword application config" do
    Application.put_env(:jido_mcp, :endpoints,
      runtime: %{
        transport: {:stdio, [command: "echo"]},
        client_info: %{name: "my_app"}
      }
    )

    assert %{runtime: endpoint} = Config.endpoints()
    assert endpoint.id == :runtime
  end

  test "loads endpoint config from MFA callback returning a map" do
    Application.put_env(:jido_mcp, :endpoints, {EndpointSource, :map_endpoints, []})

    assert %{runtime: endpoint} = Config.endpoints()
    assert endpoint.id == :runtime
  end

  test "loads endpoint config from MFA callback returning {:ok, keyword}" do
    Application.put_env(:jido_mcp, :endpoints, {EndpointSource, :ok_keyword_endpoints, []})

    assert %{runtime: endpoint} = Config.endpoints()
    assert endpoint.id == :runtime
  end

  test "raises when endpoint config callback returns an invalid value" do
    Application.put_env(:jido_mcp, :endpoints, {EndpointSource, :invalid_endpoints, []})

    assert_raise ArgumentError, ~r/Invalid endpoints callback return/, fn ->
      Config.endpoints()
    end
  end
end
