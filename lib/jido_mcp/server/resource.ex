defmodule Jido.MCP.Server.Resource do
  @moduledoc """
  Behaviour for exposing Jido-side resources through MCP.
  """

  alias Anubis.Server.Frame

  @callback uri() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t() | nil
  @callback mime_type() :: String.t()
  @callback read(uri :: String.t(), frame :: Frame.t()) :: {:ok, term()} | {:error, term()}
end
