defmodule Jido.MCP.AnubisClient do
  @moduledoc false

  # This module exists so Anubis.Client.Supervisor can derive child specs.
  use Anubis.Client,
    name: "JidoMCP",
    version: "0.1.0",
    protocol_version: "2025-03-26",
    capabilities: []
end
