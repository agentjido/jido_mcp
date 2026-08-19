# Anubis to ExMCP Migration

`jido_mcp` now uses ExMCP for both client and server protocol work. Anubis is
not a dependency and there is no backend selection setting.

## Qualified version

`jido_mcp` pins ExMCP `1.0.0-rc.8` from Hex. This exact version is used by the
tool, resource, prompt, retry, cancellation, timeout, credential isolation, and
process cleanup tests.

## Public client API

The following Jido APIs keep their names and result envelope keys:

- `Jido.MCP.list_tools/2` and `Jido.MCP.call_tool/4`
- resource and prompt functions
- endpoint registration, refresh, readiness, status, and removal
- Jido actions and plugin routes

The `raw` value in a successful envelope is now always the ExMCP result map.

Remove `backend: :anubis`, `backend: :ex_mcp`, and
`config :jido_mcp, :default_backend, ...` from endpoint configuration. A
`backend: :ex_mcp` endpoint marker is accepted during this migration, but it
has no selection effect. Other backend values fail validation.

Runtime string endpoint identifiers remain strings. `jido_mcp` does not create
atoms from untrusted identifiers. Jido AI dynamic proxy generation still
requires a trusted atom endpoint identifier because Elixir module names are
atoms.

## Client transport mapping

### stdio

The existing stdio shape is accepted:

```elixir
transport:
  {:stdio,
   [
     command: "node",
     args: ["server.js"],
     cwd: "/srv/mcp",
     env: %{"NODE_ENV" => "production"}
   ]}
```

The adapter maps `command` and `args` to the ExMCP command list. It maps `cwd`
to `cd`. The `env` option can be a map or a list of key and value tuples.
Command parts, working directories, environment names, and environment values
are validated before the client starts.

### Streamable HTTP

The existing `base_url` and `mcp_path` fields map to the ExMCP `url` and
`endpoint` fields. The `enable_sse` field maps to `use_sse`. Request headers,
auth providers, network policy, and finite transport timeouts are forwarded.

The base URL cannot contain user information, a query, a fragment, or an
unmapped path. The MCP path cannot contain a query. Put authorization data in a
header or an auth provider. Header names and values are bounded and validated.
Duplicate header names are rejected without regard to letter case.

### BEAM-local

An endpoint can use a live ExMCP server process in the same VM:

```elixir
transport: {:beam, [server: server_pid]}
```

### Legacy HTTP+SSE

The deprecated `{:sse, ...}` client shape is not supported. Migrate the server
to Streamable HTTP before this release. Endpoint validation returns
`{:unsupported_transport, :sse, :ex_mcp}` for this shape.

## Authorization and client ownership

Static request headers stay in the Streamable HTTP transport options. For
short-lived credentials, use an ExMCP `auth_provider` in `client_options` so
the host supplies authorization data at request time.

`jido_mcp` does not write authorization data to persistent storage or include
it in public errors. Each endpoint has its own supervisor and ExMCP client
process. Two endpoints cannot share authenticated client or session state.

`client_options` cannot replace transport identity, credentials, lifecycle
settings, request limits, or retry settings. Put these settings in the
documented endpoint fields. Operation and readiness timeouts must be finite
positive integers.

ExMCP `1.0.0-rc.8` sends its own legacy `clientInfo` during initialization. It
does not use the endpoint `client_info` value in that request. It also uses
endpoint client capabilities only in the modern discovery flow. Test servers
that require a specific legacy client identity before the release.

## Tool retry safety

Generic tool calls use these controls:

```elixir
retry_policy: false,
http_stream_retry: :safe_only,
retry_safe: false
```

If response delivery is ambiguous, the public error has reason
`:outcome_unknown`. The client does not retry the tool.

Set `retry_safe: true` only when the server has a tested idempotency contract:

```elixir
Jido.MCP.call_tool(:billing, "charge", arguments,
  retry_safe: true,
  idempotency_key: order_id,
  idempotency_key_path: ["request", "idempotencyKey"]
)
```

## Server migration

The `use Jido.MCP.Server` macro and explicit `publish` allowlist stay. The macro
now implements `ExMCP.Server.Handler`.

For Phoenix or Plug, use the Jido-owned host adapter. Do not reference
`ExMCP.HttpPlug` from the host application:

```elixir
forward "/mcp", Jido.MCP.Server.Plug,
  Jido.MCP.Server.plug_init_opts(MyApp.MCPServer,
    request_context: &MyApp.MCPAuth.request_context/2,
    limits: [
      allowed_hosts: ["mcp.example.com"],
      allowed_origins: ["https://app.example.com"],
      body_bytes: 1_000_000,
      response_bytes: 1_000_000,
      handler_deadline_ms: 10_000
    ]
  )
```

The required `request_context` callback runs for every POST and DELETE before
session resolution. It must re-authenticate the request and return only
redacted `assigns`, `principal_id`, and `tenant_id` values. A session is bound
to the stable identity values, and DELETE removes it. The adapter does not put
the Plug connection, request headers, bearer tokens, or connector credentials
in a Jido action context. Optional lifecycle hooks receive redacted request
and session events with a bounded callback deadline.

`Jido.MCP.Server.server_children/2` no longer returns an Anubis registry child.
It returns the allowlisted server child only. `:streamable_http` remains a Jido
alias and starts the ExMCP HTTP transport.

Resource, prompt, and authorization callbacks now receive
`Jido.MCP.Server.Context`. This context contains `assigns`, the validated ExMCP
request context, and safe transport identity fields. Code that pattern matches
`Anubis.Server.Frame` must change to the Jido context.

## Release decision

The normal client call API and envelopes remain compatible. Full removal still
changes the documented server plug, callback context type, raw response type,
and legacy HTTP+SSE support. A major release is the safe semantic-versioning
choice unless all downstream users confirm that they do not use these paths.

ExMCP currently brings `cowlib 2.19.0`, which is the newest compatible release.
This package acknowledges only `EEF-CVE-2026-43966` and
`EEF-CVE-2026-43969`. Plug and Cowboy reject the affected response header
bytes, and ExMCP does not import the affected cookie encoder. The security
tests lock these controls. `mix hex.audit` continues to fail for each new
advisory. Remove the acknowledgements by 2026-09-12 or when a fixed `cowlib`
release is available.

Before release:

- run the `jido_connect_mcp` and host integration suites;
- replace the ExMCP release candidate with stable 1.0 when it is available;
- review the temporary `cowlib` advisory controls for the target deployments;
- test any server that checks the legacy client identity;
- complete a production soak for client, session, cancellation, and subprocess
  cleanup.
