# Jido MCP 2.0 Final API Inventory

Version 2.0.0 is the final `jido_mcp` release. The package is deprecated and
will not receive updates. Jido Action v2 is the final Action contract.

The tables below record the final release inventory. They do not create a
support or update promise.

## Client API

| Module | Supported functions | State |
| --- | --- | --- |
| `Jido.MCP` | `register_endpoint/1`, `unregister_endpoint/1`, `list_tools/2`, `call_tool/4`, `list_resources/2`, `list_resource_templates/2`, `read_resource/3`, `list_prompts/2`, `get_prompt/4`, `refresh_endpoint/1`, `await_endpoint_ready/2`, `endpoint_status/1` | Supported and frozen |
| `Jido.MCP.Endpoint` | `new/2` and the public struct | Supported and frozen |
| `Jido.MCP.Config` | `endpoints/0`, `fetch_endpoint/1`, `endpoint_ids/0`, `resolve_endpoint_id/2`, `normalize_endpoints/1` | Supported and frozen |
| `Jido.MCP.ClientPool` | `start_link/1`, `ensure_client/1`, `await_ready/2`, `register_endpoint/1`, `unregister_endpoint/1`, `fetch_endpoint/1`, `endpoints/0`, `endpoint_ids/0`, `resolve_endpoint_id/1`, `endpoint_status/1`, `refresh/1` | Supported compatibility surface; no new pool features |
| `Jido.MCP.Response` | `normalize/3` | Supported envelope boundary |

The `Jido.MCP` client calls keep their current success and error envelope keys.
The `raw` success value contains the ExMCP result map.

## Jido Action v2 API

These Action modules stay available:

- `Jido.MCP.Actions.ListTools`
- `Jido.MCP.Actions.CallTool`
- `Jido.MCP.Actions.ListResources`
- `Jido.MCP.Actions.ListResourceTemplates`
- `Jido.MCP.Actions.ReadResource`
- `Jido.MCP.Actions.ListPrompts`
- `Jido.MCP.Actions.GetPrompt`
- `Jido.MCP.Actions.RegisterEndpoint`
- `Jido.MCP.Actions.RefreshEndpoint`
- `Jido.MCP.Actions.UnregisterEndpoint`
- `Jido.MCP.Actions.SetDefaultEndpoint`
- `Jido.MCP.JidoAI.Actions.SyncToolsToAgent`
- `Jido.MCP.JidoAI.Actions.UnsyncToolsFromAgent`

Each module keeps the Jido Action v2 `run/2`, schema, validation, metadata, and
tool projection functions that `use Jido.Action` generates. These modules are
frozen. The package will not add a new MCP Action.

## Plugin API

`Jido.MCP.Plugins.MCP` and `Jido.MCP.JidoAI.Plugins.MCPAI` stay available.
They keep their current Jido Plugin callbacks, metadata functions, Action
lists, and signal routes. The routes in the README are the supported route
set. The package will not add a route or plugin feature.

Dynamic Jido AI proxy Actions remain a frozen compatibility feature. They do
not move to Jido Connect.

## Server API

| Module | Supported functions or callbacks | State |
| --- | --- | --- |
| `Jido.MCP.Server` | `use Jido.MCP.Server`, `server_children/2`, `plug_init_opts/2` | Supported and frozen |
| `Jido.MCP.Server.Plug` | `validate_options/1`, `init/1`, `call/2` | Supported host adapter |
| `Jido.MCP.Server.Context` | The public struct passed to callbacks | Final callback context |
| `Jido.MCP.Server.Resource` | `name/0`, `uri/0`, `description/0`, `mime_type/0`, and `read/2` callbacks | Supported behavior contract |
| `Jido.MCP.Server.Prompt` | `name/0`, `description/0`, `arguments_schema/0`, and `messages/2` callbacks | Supported behavior contract |

Server publication stays in `jido_mcp` for compatibility. Use ExMCP for new
server and direct protocol work. Use Jido Connect for managed MCP connections
and tool calls.

## Internal Modules

The following modules have `@moduledoc false` and are internal:

```text
Jido.MCP.Application
Jido.MCP.EndpointID
Jido.MCP.ExMCPClient
Jido.MCP.Actions.Helpers
Jido.MCP.JidoAI.ProxyGenerator
Jido.MCP.JidoAI.ProxyRegistry
Jido.MCP.SchemaAdapter
Jido.MCP.SchemaAdapter.JSV
Jido.MCP.SchemaAdapter.StrictSubset
Jido.MCP.Server.Runtime
Jido.MCP.Server.SessionLimiter
```

OTP callbacks and generated Jido callbacks are implementation details when
they are not named in the supported tables.

## Future Work

- Direct MCP protocol, client, server, and transport work goes to ExMCP.
- Connector discovery and safe MCP tool calls go to Jido Connect.
- ACP and coding-agent lifecycle work goes to Jido Harness.

The package is deprecated. The [deprecation record](deprecation_plan.md)
records the replacement map and repository-retention decision.
