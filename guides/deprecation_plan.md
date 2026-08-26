# Jido MCP Deprecation Plan

**Status: Draft and inactive.**

`jido_mcp` is in maintenance mode. It is not deprecated or retired. This plan
prepares a later announcement. Do not publish the announcement, change Hex
release status, archive the repository, or set support dates without explicit
user approval.

## Purpose

Version 2.0 is the final active major line. It keeps the frozen Jido
compatibility API on stable ExMCP. During maintenance, the package accepts
security fixes and severe compatibility fixes. It does not accept new
features.

Formal deprecation can start only when all announcement gates in this document
pass. Package retirement is a separate later action after the announced
support window ends.

## Replacement Map

There is no one-package replacement for all `jido_mcp` features. Select the
owner for each use:

| Current `jido_mcp` use | Replacement |
| --- | --- |
| Direct MCP clients, transports, tools, resources, and prompts | ExMCP |
| MCP server publication, server handlers, resources, prompts, and protocol behavior | ExMCP |
| Reviewed MCP tool discovery and calls with connection, lease, scope, policy, approval, schema-drift, and uncertain-write controls | Core Jido Connect MCP bridge |
| `Jido.MCP.Actions.ListTools` and `Jido.MCP.Actions.CallTool` | The two generated Jido Connect Action v2 modules |
| Endpoint registration and the general shared client pool | Host-supervised ExMCP clients, or a connection-scoped Jido Connect lease endpoint for the narrow tool bridge |
| Dynamic Jido AI proxy Actions | No direct replacement in Connect. Use reviewed `Jido.Connect.Catalog.Item` values, packs, and `call_item/3` for connector operations. |
| Resource, prompt, endpoint-lifecycle, and server Jido Actions | No Connect replacement. Use ExMCP through explicit host-owned Action v2 modules if the host needs Actions. |
| `Jido.MCP.Plugins.MCP` and `Jido.MCP.JidoAI.Plugins.MCPAI` | No drop-in plugin replacement. Use Connect catalog and generated Action v2 modules for reviewed connectors, or host-owned ExMCP integration code. |
| ACP and coding-agent process lifecycles | Jido Harness |

Jido Connect does not replace MCP resources, prompts, server publication,
dynamic proxy Actions, or a general endpoint pool.

## Announcement Gates

All gates must pass before formal deprecation starts:

1. A stable Jido Connect release that contains the core MCP bridge is public
   on Hex.
2. The public Connect documentation gives a tested path for tool discovery,
   list, call, scopes, policy, approval, schema drift, and uncertain writes.
3. At least one supported host integration has completed the agreed production
   proof period on the public Connect release.
4. Open migration defects are reviewed. No unresolved defect blocks a
   supported replacement path.
5. The final `jido_mcp` active release is public and its security checks pass.
6. The package owners approve the announcement text, replacement version
   floors, support-window length, start date, end date, and communication
   channels.

Current gate state: not ready. The Connect replacement is a release candidate
and is not on Hex. No support window is active.

## Support-Window Inputs

The approval record must contain these values. This draft does not select
them:

- the public Jido Connect replacement version;
- the final supported `jido_mcp` version and branch;
- the announcement date;
- the support-window length and end date;
- the production proof period and evidence;
- the security-fix severity threshold;
- the severe compatibility-fix threshold;
- the response channel for private security reports;
- the issue policy for migration defects and feature requests;
- the release and communication owners;
- the date for a separate retirement review.

During the window, maintainers accept security fixes and severe compatibility
fixes on the final supported branch. They can correct migration documentation.
They do not add features, protocol extensions, Connect features, or Harness
features.

## Draft Announcement

The following text is a template. Replace every bracketed value and get
explicit approval before use:

> `jido_mcp` is deprecated as of [announcement date]. Version [final supported
> version] receives security and severe compatibility fixes through [support
> window end]. For direct MCP client, server, transport, resource, prompt, and
> protocol work, use ExMCP [minimum version]. For reviewed MCP tool discovery
> and calls with Jido connector safety controls, use Jido Connect [minimum
> version]. For ACP and coding-agent lifecycles, use Jido Harness [minimum
> version]. See [migration guide URL] for the feature-by-feature map. This
> notice does not mean that the package or repository is deleted.

The announcement must link to this replacement map and the ExMCP migration
guide. It must state that Connect is not a replacement for resources, prompts,
servers, dynamic proxies, or a general endpoint pool.

## Repository Retention Policy

After deprecation starts:

- keep the repository, full Git history, tags, release artifacts, license, and
  final documentation available;
- keep the final supported branch open for approved maintenance fixes during
  the support window;
- keep CI and dependency security checks active for that branch;
- direct feature requests to the correct replacement owner;
- keep private security reporting available;
- do not delete source, rewrite tags, or remove historical documentation.

Repository archival is not part of the deprecation announcement. Review it
only after the support window ends and after all accepted fixes are released.
Archival needs explicit approval. If approved, retain the repository as a
read-only historical source.

## Retirement Gate

Do not retire a Hex release when deprecation is announced. Review retirement
only after:

1. the approved support window has ended;
2. all accepted security and severe compatibility fixes are released;
3. replacement links and version floors are still correct;
4. the repository retention decision is recorded;
5. package owners give explicit retirement approval.

Only an approved release operator can run a Hex retirement command. This plan
does not run one and does not authorize one.

## Activation Checklist

When the announcement gates pass and approval is present:

1. replace all template values in the draft announcement;
2. update the README status from maintenance to deprecated;
3. add the approved support dates and supported version to this guide;
4. publish the notice through the approved channels;
5. create the maintenance and retirement-review issues;
6. publish or change package metadata only if the approval includes that
   action;
7. keep retirement and repository archival as separate approval gates.

Until then, keep this guide marked `Draft and inactive`.
