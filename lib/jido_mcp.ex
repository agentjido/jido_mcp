defmodule Jido.MCP do
  @moduledoc """
  Public API for calling MCP servers through direct Anubis client integration.
  """

  alias Jido.MCP.{ClientPool, Endpoint, Response}

  @type endpoint_id :: atom()
  @type result :: {:ok, map()} | {:error, map()}

  @spec register_endpoint(Endpoint.t()) ::
          {:ok, Endpoint.t()}
          | {:error, {:endpoint_already_registered, atom()} | {:invalid_endpoint, term()}}
  def register_endpoint(endpoint) do
    ClientPool.register_endpoint(endpoint)
  end

  @spec list_tools(endpoint_id(), keyword()) :: result()
  def list_tools(endpoint_id, opts \\ []) when is_atom(endpoint_id) do
    execute(endpoint_id, "tools/list", opts, fn client, call_opts ->
      Anubis.Client.list_tools(client, call_opts)
    end)
  end

  @spec call_tool(endpoint_id(), String.t(), map(), keyword()) :: result()
  def call_tool(endpoint_id, tool_name, arguments \\ %{}, opts \\ [])
      when is_atom(endpoint_id) and is_binary(tool_name) and is_map(arguments) do
    execute(endpoint_id, "tools/call", opts, fn client, call_opts ->
      Anubis.Client.call_tool(client, tool_name, arguments, call_opts)
    end)
  end

  @spec list_resources(endpoint_id(), keyword()) :: result()
  def list_resources(endpoint_id, opts \\ []) when is_atom(endpoint_id) do
    execute(endpoint_id, "resources/list", opts, fn client, call_opts ->
      Anubis.Client.list_resources(client, call_opts)
    end)
  end

  @spec list_resource_templates(endpoint_id(), keyword()) :: result()
  def list_resource_templates(endpoint_id, opts \\ []) when is_atom(endpoint_id) do
    execute(endpoint_id, "resources/templates/list", opts, fn client, call_opts ->
      Anubis.Client.list_resource_templates(client, call_opts)
    end)
  end

  @spec read_resource(endpoint_id(), String.t(), keyword()) :: result()
  def read_resource(endpoint_id, uri, opts \\ []) when is_atom(endpoint_id) and is_binary(uri) do
    execute(endpoint_id, "resources/read", opts, fn client, call_opts ->
      Anubis.Client.read_resource(client, uri, call_opts)
    end)
  end

  @spec list_prompts(endpoint_id(), keyword()) :: result()
  def list_prompts(endpoint_id, opts \\ []) when is_atom(endpoint_id) do
    execute(endpoint_id, "prompts/list", opts, fn client, call_opts ->
      Anubis.Client.list_prompts(client, call_opts)
    end)
  end

  @spec get_prompt(endpoint_id(), String.t(), map(), keyword()) :: result()
  def get_prompt(endpoint_id, prompt_name, arguments \\ %{}, opts \\ [])
      when is_atom(endpoint_id) and is_binary(prompt_name) and is_map(arguments) do
    execute(endpoint_id, "prompts/get", opts, fn client, call_opts ->
      Anubis.Client.get_prompt(client, prompt_name, arguments, call_opts)
    end)
  end

  @spec refresh_endpoint(endpoint_id()) :: result()
  def refresh_endpoint(endpoint_id) when is_atom(endpoint_id) do
    with {:ok, _endpoint, _ref} <- ClientPool.refresh(endpoint_id),
         {:ok, _} = listed <- list_tools(endpoint_id) do
      listed
    end
  end

  @spec endpoint_status(endpoint_id()) :: {:ok, map()} | {:error, term()}
  def endpoint_status(endpoint_id) when is_atom(endpoint_id) do
    ClientPool.endpoint_status(endpoint_id)
  end

  defp execute(endpoint_id, method, opts, fun) do
    with {:ok, endpoint, ref} <- ClientPool.ensure_client(endpoint_id) do
      timeout = Keyword.get(opts, :timeout, endpoint.timeouts.request_ms)
      ready_timeout = Keyword.get(opts, :ready_timeout, timeout)

      call_opts =
        opts
        |> Keyword.delete(:ready_timeout)
        |> Keyword.put_new(:timeout, timeout)

      case ClientPool.await_ready(ref, ready_timeout) do
        :ok ->
          response =
            :global.trans({__MODULE__, endpoint_id}, fn ->
              fun.(ref.client, call_opts)
            end)

          Response.normalize(endpoint_id, method, response)

        {:error, reason} ->
          Response.normalize(endpoint_id, method, {:error, reason})
      end
    end
  end
end
