# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Added `mcp.endpoint.default.set` route and `Jido.MCP.Actions.SetDefaultEndpoint` for runtime default endpoint updates.
- Added runtime endpoint unregistration APIs: `Jido.MCP.unregister_endpoint/1` and `Jido.MCP.ClientPool.unregister_endpoint/1`.
- Added `Jido.MCP.await_endpoint_ready/2` public readiness API.
- Added MCP plugin runtime endpoint signals: `mcp.endpoint.register` and `mcp.endpoint.unregister`.

### Changed

- MCP plugin allowlists now support `allowed_endpoints: :all`.
- Removed implicit MCP core -> MCPAI runtime sync coupling; host apps now orchestrate lifecycle + sync explicitly through plugin signals.
- Endpoint calls now wait on `Anubis.Client.await_ready/2` before executing.
- `Jido.MCP.refresh_endpoint/1` now refreshes lifecycle only and no longer performs `tools/list`.
- Removed MCPAI orchestration shims from `Jido.MCP`; runtime sync is triggered via MCPAI plugin signals.

## [0.1.1] - 2026-02-25

### Changed

- Switched `anubis_mcp` from a local path dependency to Hex (`~> 0.17.0`).
- Switched `jido` from a local path dependency to Hex (`~> 2.0`) so the package can be published on Hex.
- Updated release metadata in `mix.exs` (package files, maintainers, docs links, and release check alias).
- Updated `ex_doc` development dependency to `~> 0.40`.
