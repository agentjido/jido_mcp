# ExMCP Client Migration

This guide applies to the consume-side `Jido.MCP` endpoint runtime. The
`Jido.MCP.Server` allowlist and server bridge continue to use Anubis.

## Qualified version

`jido_mcp` pins ExMCP `1.0.0-rc.8` from Hex. This is the version used for the
backend parity, retry-safety, cancellation, timeout, and cleanup tests.

Anubis `2.0.0` stays installed and stays the default backend. Existing endpoint
configuration does not select ExMCP unless the application changes the default.

## Select ExMCP

Select the backend on one endpoint:

```elixir
config :jido_mcp, :endpoints,
  remote: %{
    backend: :ex_mcp,
    transport:
      {:streamable_http,
       [base_url: "https://mcp.example", mcp_path: "/mcp"]},
    client_info: %{name: "my_app", version: "1.0.0"},
    timeouts: %{request_ms: 30_000}
  }
```

Or set the application default:

```elixir
config :jido_mcp, :default_backend, :ex_mcp
```

An explicit endpoint `:backend` value takes precedence over the application
default. The accepted built-in values are `:anubis` and `:ex_mcp`. Known string
values are also accepted without conversion of an endpoint identifier to an
atom.

Runtime registration keeps a string endpoint identifier as a string. Existing
atom identifiers and configured atom keys continue to work.

Jido AI dynamic proxy generation requires a trusted atom endpoint identifier.
It rejects a string endpoint identifier because an Elixir module name is an
atom. Normal MCP calls and actions continue to support string identifiers.

## Transport mapping

### stdio

The existing shape is accepted:

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

The backend maps `command` and `args` to the ExMCP command list. It maps `cwd`
to `cd`. The `env` option can be a map or a list of key and value tuples.
Command parts, working directories, environment names, and environment values
are validated before the client starts. ExMCP uses its isolated child-process
environment policy unless the transport explicitly selects another policy.

### Streamable HTTP

The backend maps `base_url` and `mcp_path` to the ExMCP `url` and `endpoint`
options. It maps `enable_sse` to `use_sse`. It forwards headers, ExMCP auth
providers, network policy, and finite transport timeout options.

The backend does not map an MCP path that contains a URL query. Move
authorization data from the URL to a header or an auth provider. The backend
returns `{:unsupported_transport_option, :mcp_path_query}` for this case.
The base URL cannot contain user information, a query, a fragment, or an
unmapped path. Header names and values are bounded and validated. Duplicate
header names are rejected without regard to letter case.

### BEAM-local

ExMCP endpoints can use a local server process:

```elixir
transport: {:beam, [server: server_pid]}
```

### Legacy HTTP+SSE

The Anubis `{:sse, ...}` endpoint shape does not have a behavior-preserving
ExMCP mapping. Keep `backend: :anubis` for these endpoints. An ExMCP endpoint
returns `{:unsupported_transport, :sse, :ex_mcp}` when it starts.

## Authorization and client ownership

Static request headers can stay in the Streamable HTTP transport options. For
short-lived credentials, use an ExMCP `auth_provider` in `backend_options` so
the host supplies authorization data at request time.

`jido_mcp` does not write authorization data to persistent storage and does not
include it in its errors. ExMCP stores the active transport or auth-provider
state in the endpoint client process while the connection is active.

Each endpoint has its own supervisor and client process. Registry names use the
existing endpoint identifier. Two endpoint identifiers cannot share an authenticated
client or session, even when they connect to the same URL.

`backend_options` cannot replace transport identity, credentials, lifecycle
settings, request limits, or retry settings. Put transport settings in the
endpoint transport options. ExMCP operation and readiness timeouts must be
finite positive integers.

## Tool retry safety

The ExMCP backend applies these options to every generic tool call:

```elixir
retry_policy: false,
http_stream_retry: :safe_only,
retry_safe: false
```

If response delivery is ambiguous, the public error has reason
`:outcome_unknown`. The backend does not retry the tool.

The caller can attest a tested idempotency contract:

```elixir
Jido.MCP.call_tool(:billing, "charge", arguments,
  retry_safe: true,
  idempotency_key: order_id,
  idempotency_key_path: ["request", "idempotencyKey"]
)
```

The server must use the key to deduplicate the operation. Tool annotations are
not an idempotency guarantee.

## Public compatibility

The following interfaces do not change:

- `Jido.MCP.list_tools/2` and `call_tool/4`
- resource and prompt functions
- endpoint register, refresh, readiness, status, and unregister functions
- success and error envelope keys
- the `Jido.MCP.Server` explicit allowlist contract

For ExMCP success envelopes, `raw` is the raw ExMCP result map. Anubis
endpoints continue to return an `Anubis.MCP.Response` in `raw`.

ExMCP `1.0.0-rc.8` sends its own legacy `clientInfo` during initialization. It
does not use the endpoint `client_info` value in that legacy request. It also
uses endpoint client capabilities only in the modern discovery flow. Keep an
endpoint on Anubis if the server requires the configured legacy client identity
or legacy client capabilities.

## Release decision

Do not make ExMCP the default in the current major version. A default change
changes transport and response behavior and must use a major release unless a
future compatibility review proves that no observable behavior changes.

The ExMCP default gate requires all of these results:

- the supported stdio and Streamable HTTP parity tests pass in CI;
- downstream `jido_connect_mcp` and host integration suites pass;
- a stable ExMCP 1.0 release replaces the release candidate;
- the ExMCP legacy client identity and capability gaps are resolved or accepted;
- active advisories in `cowlib` are fixed or formally accepted for the intended
  deployments;
- an opt-in release completes a production soak without client, session,
  cancellation, or subprocess leaks.

Remove the Anubis client backend only in a later major release. Before removal,
publish a deprecation period and provide a behavior-preserving path for legacy
HTTP+SSE endpoints. Keep the Anubis server bridge until a separate server
migration preserves the explicit allowlist contract.
