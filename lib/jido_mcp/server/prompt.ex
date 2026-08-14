defmodule Jido.MCP.Server.Prompt do
  @moduledoc """
  Behaviour for exposing prompt templates through MCP.
  """

  alias Jido.MCP.Server.Context

  @callback name() :: String.t()
  @callback description() :: String.t() | nil
  @callback arguments_schema() :: map()
  @callback messages(arguments :: map(), context :: Context.t()) ::
              {:ok, [map()]} | {:error, term()}
end
