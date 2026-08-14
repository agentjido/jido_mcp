defmodule Jido.MCP.Backend.Anubis do
  @moduledoc false

  @behaviour Jido.MCP.Backend

  alias Jido.MCP.Endpoint

  @impl true
  def child_spec(%Endpoint{transport: {:stdio, transport_opts}} = endpoint, ref) do
    client_opts = [
      transport: [layer: Anubis.Transport.STDIO, name: ref.transport],
      client_info: endpoint.client_info,
      capabilities: endpoint.capabilities,
      protocol_version: endpoint.protocol_version,
      name: ref.client
    ]

    children = [
      %{id: Anubis.Client, start: {Anubis.Client, :start_link_server, [client_opts]}},
      {Jido.MCP.Transport.STDIO, transport_opts ++ [name: ref.transport, client: ref.client]}
    ]

    {:ok,
     %{
       id: {:mcp_client, endpoint.id},
       start:
         {Supervisor, :start_link, [children, [strategy: :one_for_all, name: ref.supervisor]]},
       type: :supervisor,
       restart: :transient,
       shutdown: 10_000
     }}
  end

  def child_spec(%Endpoint{} = endpoint, ref) do
    {:ok,
     %{
       id: {:mcp_client, endpoint.id},
       start:
         {Anubis.Client.Supervisor, :start_link,
          [
            [
              name: ref.client,
              transport_name: ref.transport,
              transport: endpoint.transport,
              client_info: endpoint.client_info,
              capabilities: endpoint.capabilities,
              protocol_version: endpoint.protocol_version
            ]
          ]},
       type: :supervisor,
       restart: :transient,
       shutdown: 10_000
     }}
  end

  @impl true
  def await_ready(%{client: client}, timeout) do
    Anubis.Client.await_ready(client, timeout: timeout)
  catch
    :exit, {:timeout, _} -> {:error, :client_not_ready}
    :exit, {:noproc, _} -> {:error, :client_not_started}
    :exit, reason -> {:error, reason}
  end

  @impl true
  def sanitize_start_error(reason), do: reason

  @impl true
  def list_tools(client, opts), do: Anubis.Client.list_tools(client, opts)

  @impl true
  def call_tool(client, tool_name, arguments, opts) do
    Anubis.Client.call_tool(client, tool_name, arguments, opts)
  end

  @impl true
  def list_resources(client, opts), do: Anubis.Client.list_resources(client, opts)

  @impl true
  def list_resource_templates(client, opts) do
    Anubis.Client.list_resource_templates(client, opts)
  end

  @impl true
  def read_resource(client, uri, opts), do: Anubis.Client.read_resource(client, uri, opts)

  @impl true
  def list_prompts(client, opts), do: Anubis.Client.list_prompts(client, opts)

  @impl true
  def get_prompt(client, prompt_name, arguments, opts) do
    Anubis.Client.get_prompt(client, prompt_name, arguments, opts)
  end
end
