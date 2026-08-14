defmodule Jido.MCP.Server.Context do
  @moduledoc """
  Request context passed to Jido MCP server actions, resources, prompts, and
  authorization callbacks.

  The struct keeps the stable Jido-facing context boundary while ExMCP owns the
  protocol and transport request context.
  """

  alias ExMCP.Server.Context, as: ExMCPContext
  alias ExMCP.Server.RequestContext

  @type t :: %__MODULE__{
          assigns: map(),
          context: RequestContext.t() | nil,
          request: RequestContext.t() | nil,
          transport: map()
        }

  defstruct assigns: %{}, context: nil, request: nil, transport: %{}

  @doc false
  @spec new(term()) :: t()
  def new(state) do
    request = ExMCPContext.current()

    %__MODULE__{
      assigns: assigns(state),
      context: request,
      request: request,
      transport: transport(request)
    }
  end

  defp assigns(%{assigns: assigns}) when is_map(assigns), do: assigns
  defp assigns(_state), do: %{}

  defp transport(%RequestContext{} = request) do
    %{
      endpoint: request.endpoint,
      principal_id: request.principal_id,
      tenant_id: request.tenant_id
    }
  end

  defp transport(nil), do: %{}
end
