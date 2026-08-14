defmodule Jido.MCP.Backend do
  @moduledoc """
  Contract for an MCP client implementation used by an endpoint.

  `:anubis` stays the default backend for compatibility. An endpoint can select
  `:ex_mcp`, or a host can configure a module that implements this behaviour.
  """

  alias Jido.MCP.Endpoint

  @type client_ref :: %{
          required(:backend) => module(),
          required(:client) => GenServer.server(),
          required(:supervisor) => GenServer.server(),
          required(:transport) => GenServer.server()
        }

  @callback child_spec(Endpoint.t(), client_ref()) ::
              {:ok, Supervisor.child_spec()} | {:error, term()}
  @callback await_ready(client_ref(), timeout()) :: :ok | {:error, term()}
  @callback sanitize_start_error(term()) :: term()
  @callback list_tools(GenServer.server(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback call_tool(GenServer.server(), String.t(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback list_resources(GenServer.server(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback list_resource_templates(GenServer.server(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback read_resource(GenServer.server(), String.t(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback list_prompts(GenServer.server(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_prompt(GenServer.server(), String.t(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}

  @spec default() :: :anubis | :ex_mcp | module()
  def default do
    Application.get_env(:jido_mcp, :default_backend, :anubis)
  end

  @spec normalize(term()) :: {:ok, :anubis | :ex_mcp | module()} | {:error, term()}
  def normalize(:anubis), do: {:ok, :anubis}
  def normalize("anubis"), do: {:ok, :anubis}
  def normalize(:ex_mcp), do: {:ok, :ex_mcp}
  def normalize("ex_mcp"), do: {:ok, :ex_mcp}

  def normalize(module) when is_atom(module) do
    if backend_module?(module) do
      {:ok, module}
    else
      {:error,
       {:invalid_backend, module,
        "backend must be :anubis, :ex_mcp, or a module that implements Jido.MCP.Backend"}}
    end
  end

  def normalize(other) do
    {:error,
     {:invalid_backend, other,
      "backend must be :anubis, :ex_mcp, or a module that implements Jido.MCP.Backend"}}
  end

  @spec module_for(:anubis | :ex_mcp | module()) :: module()
  def module_for(:anubis), do: Jido.MCP.Backend.Anubis
  def module_for(:ex_mcp), do: Jido.MCP.Backend.ExMCP
  def module_for(module) when is_atom(module), do: module

  defp backend_module?(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(behaviour_callbacks(), fn {name, arity} ->
        function_exported?(module, name, arity)
      end)
  end

  defp behaviour_callbacks do
    __MODULE__.behaviour_info(:callbacks)
  end
end
