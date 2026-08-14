defmodule Jido.MCP.Server.Resource do
  @moduledoc """
  Behaviour for exposing Jido-side resources through MCP.
  """

  alias Jido.MCP.Server.Context

  @callback uri() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t() | nil
  @callback mime_type() :: String.t()
  @callback read(uri :: String.t(), context :: Context.t()) :: {:ok, term()} | {:error, term()}
end
