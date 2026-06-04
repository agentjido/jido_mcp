defmodule Jido.MCP.JidoAI.SchemaAdapter do
  @moduledoc """
  Behaviour for pluggable JSON Schema engines used by Jido MCP's JidoAI proxy
  integration.

  Allows swapping the strict built-in validator (which rejects many valid JSON
  Schema constructs) for a full engine like JSV (supporting Draft 2020-12
  including $ref, oneOf, etc.).

  This makes it possible to use real-world MCP servers that return richer
  inputSchemas.

  ## Example

      adapter = Jido.MCP.JidoAI.SchemaAdapter.JSV
      {:ok, compiled} = adapter.compile(tool["inputSchema"], [])
      :ok = adapter.validate(compiled, params)
  """

  @type compiled_schema :: term()
  @type validation_error :: %{code: atom(), message: String.t(), path: [term()]}

  @callback compile(map() | nil, keyword()) ::
              {:ok, compiled_schema()} | {:error, validation_error()}

  @callback validate(compiled_schema(), map()) ::
              :ok | {:error, validation_error()}
end
