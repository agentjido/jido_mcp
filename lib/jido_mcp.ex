defmodule Jido.MCP do
  @moduledoc """
  Public API for calling MCP servers through endpoint-selected client backends.
  """

  alias Jido.MCP.{ClientPool, Endpoint, Response}

  @type endpoint_id :: Endpoint.id()
  @type result :: {:ok, map()} | {:error, map()}

  defguardp is_endpoint_id(endpoint_id) when is_atom(endpoint_id) or is_binary(endpoint_id)

  @spec register_endpoint(Endpoint.t()) ::
          {:ok, Endpoint.t()}
          | {:error, {:endpoint_already_registered, endpoint_id()} | {:invalid_endpoint, term()}}
  def register_endpoint(endpoint) do
    ClientPool.register_endpoint(endpoint)
  end

  @spec unregister_endpoint(endpoint_id()) :: {:ok, Endpoint.t()} | {:error, :unknown_endpoint}
  def unregister_endpoint(endpoint_id) when is_endpoint_id(endpoint_id) do
    ClientPool.unregister_endpoint(endpoint_id)
  end

  @spec list_tools(endpoint_id(), keyword()) :: result()
  def list_tools(endpoint_id, opts \\ []) when is_endpoint_id(endpoint_id) do
    execute(endpoint_id, "tools/list", opts, fn backend, client, call_opts ->
      backend.list_tools(client, call_opts)
    end)
  end

  @spec call_tool(endpoint_id(), String.t(), map(), keyword()) :: result()
  def call_tool(endpoint_id, tool_name, arguments \\ %{}, opts \\ [])
      when is_endpoint_id(endpoint_id) and is_binary(tool_name) and is_map(arguments) do
    execute(endpoint_id, "tools/call", opts, fn backend, client, call_opts ->
      backend.call_tool(client, tool_name, arguments, call_opts)
    end)
  end

  @spec list_resources(endpoint_id(), keyword()) :: result()
  def list_resources(endpoint_id, opts \\ []) when is_endpoint_id(endpoint_id) do
    execute(endpoint_id, "resources/list", opts, fn backend, client, call_opts ->
      backend.list_resources(client, call_opts)
    end)
  end

  @spec list_resource_templates(endpoint_id(), keyword()) :: result()
  def list_resource_templates(endpoint_id, opts \\ []) when is_endpoint_id(endpoint_id) do
    execute(endpoint_id, "resources/templates/list", opts, fn backend, client, call_opts ->
      backend.list_resource_templates(client, call_opts)
    end)
  end

  @spec read_resource(endpoint_id(), String.t(), keyword()) :: result()
  def read_resource(endpoint_id, uri, opts \\ [])
      when is_endpoint_id(endpoint_id) and is_binary(uri) do
    execute(endpoint_id, "resources/read", opts, fn backend, client, call_opts ->
      backend.read_resource(client, uri, call_opts)
    end)
  end

  @spec list_prompts(endpoint_id(), keyword()) :: result()
  def list_prompts(endpoint_id, opts \\ []) when is_endpoint_id(endpoint_id) do
    execute(endpoint_id, "prompts/list", opts, fn backend, client, call_opts ->
      backend.list_prompts(client, call_opts)
    end)
  end

  @spec get_prompt(endpoint_id(), String.t(), map(), keyword()) :: result()
  def get_prompt(endpoint_id, prompt_name, arguments \\ %{}, opts \\ [])
      when is_endpoint_id(endpoint_id) and is_binary(prompt_name) and is_map(arguments) do
    execute(endpoint_id, "prompts/get", opts, fn backend, client, call_opts ->
      backend.get_prompt(client, prompt_name, arguments, call_opts)
    end)
  end

  @spec refresh_endpoint(endpoint_id()) ::
          {:ok, Endpoint.t(), ClientPool.client_ref()} | {:error, term()}
  def refresh_endpoint(endpoint_id) when is_endpoint_id(endpoint_id) do
    ClientPool.refresh(endpoint_id)
  end

  @doc """
  Ensures an endpoint client is started and MCP initialization is complete.

  This is intended for flows that must guarantee server readiness before
  subsequent operations (for example runtime tool synchronization).
  """
  @spec await_endpoint_ready(endpoint_id(), keyword()) :: :ok | {:error, term()}
  def await_endpoint_ready(endpoint_id, opts \\ [])
      when is_endpoint_id(endpoint_id) and is_list(opts) do
    case ClientPool.ensure_client(endpoint_id) do
      {:ok, endpoint, ref} ->
        with :ok <- validate_keyword_options(opts),
             timeout = Keyword.get(opts, :timeout, endpoint.timeouts.request_ms),
             :ok <- validate_ex_mcp_timeout(ref, timeout) do
          ClientPool.await_ready(ref, timeout)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec endpoint_status(endpoint_id()) :: {:ok, map()} | {:error, term()}
  def endpoint_status(endpoint_id) when is_endpoint_id(endpoint_id) do
    ClientPool.endpoint_status(endpoint_id)
  end

  defp execute(endpoint_id, method, opts, fun) do
    with {:ok, endpoint, ref} <- ClientPool.ensure_client(endpoint_id) do
      case prepare_call_options(endpoint, ref, opts) do
        {:ok, call_opts, ready_timeout} ->
          ref
          |> ClientPool.await_ready(ready_timeout)
          |> execute_ready(endpoint_id, method, ref, call_opts, fun)

        {:error, error} ->
          Response.normalize(endpoint_id, method, {:error, error})
      end
    end
  end

  defp prepare_call_options(endpoint, ref, opts) do
    with :ok <- validate_keyword_options(opts),
         timeout = Keyword.get(opts, :timeout, endpoint.timeouts.request_ms),
         ready_timeout = Keyword.get(opts, :ready_timeout, timeout),
         :ok <- validate_ex_mcp_timeout(ref, timeout),
         :ok <- validate_ex_mcp_timeout(ref, ready_timeout) do
      call_opts =
        opts
        |> Keyword.delete(:ready_timeout)
        |> Keyword.put_new(:timeout, timeout)

      {:ok, call_opts, ready_timeout}
    end
  end

  defp validate_keyword_options(opts) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, invalid_options_error(:options)}
  end

  defp validate_ex_mcp_timeout(%{backend: Jido.MCP.Backend.ExMCP}, timeout)
       when is_integer(timeout) and timeout > 0,
       do: :ok

  defp validate_ex_mcp_timeout(%{backend: Jido.MCP.Backend.ExMCP}, _timeout),
    do: {:error, invalid_options_error(:timeout)}

  defp validate_ex_mcp_timeout(_ref, _timeout), do: :ok

  defp invalid_options_error(field) do
    %{
      reason: :invalid_params,
      message: "The MCP request options are invalid",
      details: %{field: field}
    }
  end

  defp execute_ready(:ok, endpoint_id, method, ref, call_opts, fun) do
    response =
      :global.trans({__MODULE__, endpoint_id}, fn ->
        backend = Map.get(ref, :backend, Jido.MCP.Backend.Anubis)
        fun.(backend, ref.client, call_opts)
      end)

    Response.normalize(endpoint_id, method, response)
  end

  defp execute_ready({:error, reason}, endpoint_id, method, _ref, _call_opts, _fun) do
    Response.normalize(endpoint_id, method, {:error, reason})
  end
end
