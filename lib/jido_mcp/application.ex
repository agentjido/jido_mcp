defmodule Jido.MCP.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Jido.MCP.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Jido.MCP.ClientSupervisor},
      Jido.MCP.ClientPool,
      Jido.MCP.JidoAI.ProxyRegistry
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Jido.MCP.Supervisor)
  end
end
