defmodule Jido.MCP.JidoAI.SchemaAdapter do
  @moduledoc false

  @type compiled_schema :: term()
  @type validation_error :: %{code: atom(), message: String.t(), path: [term()]}
  @type validation_result :: :ok | {:ok, map()} | {:error, validation_error()}

  @callback compile(map() | nil, keyword()) ::
              {:ok, compiled_schema()} | {:error, validation_error()}

  @callback validate(compiled_schema(), map()) :: validation_result()
end
