defmodule Jido.MCP.Server.Prompt do
  @moduledoc """
  Behaviour for exposing prompt templates through MCP.
  """

  alias Anubis.Server.Frame

  @callback name() :: String.t()
  @callback description() :: String.t() | nil
  @callback arguments_schema() :: map()
  @callback messages(arguments :: map(), frame :: Frame.t()) :: {:ok, [map()]} | {:error, term()}
end
