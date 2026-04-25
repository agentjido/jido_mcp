# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Added `mcp.endpoint.default.set` route and `Jido.MCP.Actions.SetDefaultEndpoint` for runtime default endpoint updates.
- Added runtime endpoint unregistration APIs: `Jido.MCP.unregister_endpoint/1` and `Jido.MCP.ClientPool.unregister_endpoint/1`.

### Changed

- MCP plugin allowlists now support `allowed_endpoints: :all`.
- Runtime endpoint register/refresh/unregister now propagate MCP tool sync updates to endpoint-subscribed Jido.AI agents.
- Added explicit assignment APIs: `Jido.MCP.sync_endpoint_to_agent/3` and `Jido.MCP.unsync_endpoint_from_agent/2`.
- MCP tool discovery sync now retries transient "Server capabilities not set" initialization failures before failing.

## [0.1.1] - 2026-02-25

### Changed

- Switched `anubis_mcp` from a local path dependency to Hex (`~> 0.17.0`).
- Switched `jido` from a local path dependency to Hex (`~> 2.0`) so the package can be published on Hex.
- Updated release metadata in `mix.exs` (package files, maintainers, docs links, and release check alias).
- Updated `ex_doc` development dependency to `~> 0.40`.
