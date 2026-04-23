require Jido.MCP.Actions.ListTools
require Jido.MCP.Actions.CallTool
require Jido.MCP.Actions.ListResources
require Jido.MCP.Actions.ListResourceTemplates
require Jido.MCP.Actions.ReadResource
require Jido.MCP.Actions.ListPrompts
require Jido.MCP.Actions.GetPrompt
require Jido.MCP.Actions.RefreshEndpoint
require Jido.MCP.Actions.SetDefaultEndpoint

defmodule Jido.MCP.Plugins.MCP do
  @moduledoc """
  Plugin exposing MCP consume-side routes (tools/resources/prompts/endpoints).
  """

  alias Jido.MCP.{ClientPool, EndpointID}

  use Jido.Plugin,
    name: "mcp",
    state_key: :mcp,
    actions: [
      Jido.MCP.Actions.ListTools,
      Jido.MCP.Actions.CallTool,
      Jido.MCP.Actions.ListResources,
      Jido.MCP.Actions.ListResourceTemplates,
      Jido.MCP.Actions.ReadResource,
      Jido.MCP.Actions.ListPrompts,
      Jido.MCP.Actions.GetPrompt,
      Jido.MCP.Actions.RefreshEndpoint,
      Jido.MCP.Actions.SetDefaultEndpoint
    ],
    description: "Model Context Protocol integration",
    category: "mcp",
    tags: ["mcp", "tools", "resources", "prompts"],
    vsn: to_string(Application.spec(:jido_mcp, :vsn) || "0.1.1")

  @impl Jido.Plugin
  def mount(_agent, config) do
    with {:ok, default_endpoint} <- normalize_default_endpoint(Map.get(config, :default_endpoint)),
         {:ok, allowed_endpoints} <-
           normalize_allowed_endpoints(Map.get(config, :allowed_endpoints)) do
      ensure_default_endpoint_allowed!(default_endpoint, allowed_endpoints)

      {:ok,
       %{
         default_endpoint: default_endpoint,
         allowed_endpoints: allowed_endpoints
       }}
    end
  end

  @impl Jido.Plugin
  def signal_routes(_config) do
    [
      {"mcp.tools.list", Jido.MCP.Actions.ListTools},
      {"mcp.tools.call", Jido.MCP.Actions.CallTool},
      {"mcp.resources.list", Jido.MCP.Actions.ListResources},
      {"mcp.resources.templates.list", Jido.MCP.Actions.ListResourceTemplates},
      {"mcp.resources.read", Jido.MCP.Actions.ReadResource},
      {"mcp.prompts.list", Jido.MCP.Actions.ListPrompts},
      {"mcp.prompts.get", Jido.MCP.Actions.GetPrompt},
      {"mcp.endpoint.refresh", Jido.MCP.Actions.RefreshEndpoint},
      {"mcp.endpoint.default.set", Jido.MCP.Actions.SetDefaultEndpoint}
    ]
  end

  @impl Jido.Plugin
  def handle_signal(_signal, _context), do: {:ok, :continue}

  @impl Jido.Plugin
  def transform_result(_action, result, _context), do: result

  defp normalize_default_endpoint(nil), do: {:ok, nil}
  defp normalize_default_endpoint(value), do: ClientPool.resolve_endpoint_id(value)

  # Fail closed: if not explicitly configured, endpoint access is denied.
  defp normalize_allowed_endpoints(nil), do: {:ok, []}
  defp normalize_allowed_endpoints(:all), do: {:ok, :all}

  defp normalize_allowed_endpoints(values) when is_list(values) do
    endpoints = ClientPool.endpoints()

    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case EndpointID.resolve(value, endpoints) do
        {:ok, endpoint_id} -> {:cont, {:ok, [endpoint_id | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_allowed_endpoints, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp normalize_allowed_endpoints(_), do: {:error, {:invalid_allowed_endpoints, :invalid_type}}

  defp ensure_default_endpoint_allowed!(nil, _allowed_endpoints), do: :ok

  defp ensure_default_endpoint_allowed!(_default_endpoint, :all), do: :ok

  defp ensure_default_endpoint_allowed!(default_endpoint, allowed_endpoints) do
    if default_endpoint in allowed_endpoints do
      :ok
    else
      raise ArgumentError,
            "default_endpoint #{inspect(default_endpoint)} must be included in allowed_endpoints"
    end
  end
end
