# Jido.MCP

`jido_mcp` integrates MCP servers into the Jido ecosystem using `anubis_mcp` directly.

## Features

- Shared pooled MCP clients per configured endpoint
- Consume-side API for MCP tools/resources/prompts
- Jido actions + plugin routes for signal-driven usage
- Jido.AI runtime tool sync (MCP tools -> proxy `Jido.Action`s)
- MCP server bridge (`use Jido.MCP.Server`) with explicit allowlists

## Installation

```elixir
def deps do
  [
    {:jido_mcp, "~> 0.1"}
  ]
end
```

## Endpoint Configuration

```elixir
config :jido_mcp, :endpoints,
  github: %{
    transport: {:streamable_http, [base_url: "http://localhost:8080", mcp_path: "/mcp"]},
    client_info: %{name: "my_app", version: "1.0.0"},
    protocol_version: "2025-06-18",
    capabilities: %{},
    timeouts: %{request_ms: 30_000}
  },
  local_fs: %{
    transport: {:stdio, [command: "uvx", args: ["mcp-server-filesystem"]]},
    client_info: %{name: "my_app", version: "1.0.0"}
  }
```

Supported transports in v1:

- `{:stdio, keyword()}` for shell/command-based MCP servers
- `{:shell, keyword()}` as an alias normalized to `:stdio`
- `{:sse, keyword()}` for legacy HTTP+SSE servers using protocol `2024-11-05`
- `{:streamable_http, keyword()}` for MCP `2025-03-26` / `2025-06-18`, including optional SSE streaming via Anubis' `:enable_sse` option

For Streamable HTTP, `:url` or a `:base_url` containing a non-root path is
normalized to Anubis' `:base_url` + `:mcp_path` option shape.

Endpoint config may also be loaded through an MFA callback:

```elixir
config :jido_mcp, :endpoints, {MyApp.MCPConfig, :endpoints, []}
```

The callback must return a map/keyword endpoint declaration or `{:ok, endpoints}`.

Runtime endpoints can be registered after application start:

```elixir
{:ok, endpoint} =
  Jido.MCP.Endpoint.new(:github, %{
    transport: {:streamable_http, [base_url: "http://localhost:8080", mcp_path: "/mcp"]},
    client_info: %{name: "my_app", version: "1.0.0"}
  })

{:ok, ^endpoint} = Jido.MCP.register_endpoint(endpoint)
```

Runtime registration is process-local, rejects duplicate endpoint ids, and starts the MCP client
only when the endpoint is first used.

## Consume MCP APIs

```elixir
{:ok, tools} = Jido.MCP.list_tools(:github)
{:ok, called} = Jido.MCP.call_tool(:github, "search_issues", %{"query" => "label:bug"})

{:ok, resources} = Jido.MCP.list_resources(:github)
{:ok, content} = Jido.MCP.read_resource(:github, "repo://owner/name/README")

{:ok, prompts} = Jido.MCP.list_prompts(:github)
{:ok, prompt} = Jido.MCP.get_prompt(:github, "release_notes", %{"version" => "1.2.0"})
```

All calls return normalized envelopes:

- success: `%{status: :ok, endpoint: atom(), method: String.t(), data: map(), raw: ...}`
- error: `%{status: :error, endpoint: atom(), type: ..., message: String.t(), details: ...}`

## Jido Actions + Plugin

### Actions

- `Jido.MCP.Actions.ListTools`
- `Jido.MCP.Actions.CallTool`
- `Jido.MCP.Actions.ListResources`
- `Jido.MCP.Actions.ListResourceTemplates`
- `Jido.MCP.Actions.ReadResource`
- `Jido.MCP.Actions.ListPrompts`
- `Jido.MCP.Actions.GetPrompt`
- `Jido.MCP.Actions.RefreshEndpoint`

### Plugin

```elixir
defmodule MyApp.Agent do
  use Jido.Agent,
    name: "assistant",
    plugins: [
      {Jido.MCP.Plugins.MCP,
       %{
         default_endpoint: :github,
         allowed_endpoints: [:github, :local_fs]
       }}
    ]
end
```

Signal routes:

- `mcp.tools.list`
- `mcp.tools.call`
- `mcp.resources.list`
- `mcp.resources.templates.list`
- `mcp.resources.read`
- `mcp.prompts.list`
- `mcp.prompts.get`
- `mcp.endpoint.refresh`

## Jido.AI Sync

`Jido.MCP.JidoAI.Actions.SyncToolsToAgent` discovers remote tools and creates proxy `Jido.Action` modules, then registers them on a running `Jido.AI.Agent`.

`Jido.MCP.JidoAI.Actions.UnsyncToolsFromAgent` removes previously synced proxies.

Plugin route support:

- `mcp.ai.sync_tools`
- `mcp.ai.unsync_tools`

## Expose Jido As MCP Server

### Server module

```elixir
defmodule MyApp.MCPServer do
  use Jido.MCP.Server,
    name: "my-app",
    version: "1.0.0",
    publish: %{
      tools: [MyApp.Actions.SearchIssues],
      resources: [MyApp.MCP.Resources.ReleaseNotes],
      prompts: [MyApp.MCP.Prompts.CodeReview]
    }
end
```

Publication is explicit allowlist only.

### Supervision

```elixir
children =
  Jido.MCP.Server.server_children(MyApp.MCPServer,
    transport: :streamable_http
  )
```

### Router (streamable HTTP)

```elixir
forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug,
  Jido.MCP.Server.plug_init_opts(MyApp.MCPServer)
```

## Resource and Prompt Behaviours

- `Jido.MCP.Server.Resource`
- `Jido.MCP.Server.Prompt`

Implement those behaviours for items listed in `publish.resources` and `publish.prompts`.

## Testing

```bash
mix test
```
