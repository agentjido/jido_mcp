# Jido MCP Deprecation Record

**Status: Active.**

`jido_mcp` is deprecated as of 2026-09-19. Version 2.0.0 is the final release.
The package will not receive new features, compatibility fixes, security fixes,
dependency updates, or new versions. There is no support window.

All published versions are retired on Hex with the `deprecated` reason. Hex
keeps retired releases available for existing lockfiles, but it shows a warning
to users. The source repository, Git history, tags, release artifacts, license,
and final documentation remain available.

## Replacement Map

There is no one-package replacement for all `jido_mcp` features.

| Current `jido_mcp` use | Replacement |
| --- | --- |
| MCP clients, transports, tools, resources, prompts, completion, and protocol behavior | ExMCP |
| MCP server publication and handlers | ExMCP |
| Endpoint registration and the shared client pool | Host-supervised ExMCP clients |
| Jido Action v2 modules | Host-owned Actions that call ExMCP |
| Dynamic Jido AI proxy Actions | No direct replacement. Use reviewed connector operations instead. |
| Managed MCP connections, reviewed connector discovery, calls, scopes, policy, approval, schema drift, notifications, and connection leases | Jido Connect |
| `Jido.MCP.Plugins.MCP` and `Jido.MCP.JidoAI.Plugins.MCPAI` | No drop-in replacement. Use host integration code with ExMCP or Jido Connect. |
| ACP and coding-agent process lifecycles | Jido Harness |

Use ExMCP for direct MCP protocol, client, server, and transport work. Use Jido
Connect for managed MCP connections and tool calls. Jido Connect does not
replace every dynamic proxy, plugin, or server API.

## Final Release

Version 2.0.0 replaces Anubis with ExMCP 1.4.0 and records the final Jido
Action v2 compatibility surface. The final release includes the migration
guide and public API inventory.

The release keeps two reviewed Cowlib audit exceptions:

- `EEF-CVE-2026-43966`
- `EEF-CVE-2026-43969`

These exceptions do not state that Cowlib is fixed. The final security tests
record the package controls. Because the package is deprecated with no support
window, no later dependency update is planned.

## Hex Retirement

The retirement reason is `deprecated`. The retirement message is:

> Deprecated. Use ExMCP for direct MCP protocol work and Jido Connect for managed MCP connections and tool calls.

Retirement does not delete a package version. Existing lockfiles can still
fetch it. New dependency resolution shows a retirement warning.

## Repository Retention

- Keep the repository and full Git history available.
- Keep tags, release artifacts, the license, and final documentation available.
- Keep the migration guide and this replacement map available.
- Do not delete source or rewrite tags.
- Do not promise fixes or new releases.

Repository archival is a separate action. This deprecation record does not
archive or delete the repository.
