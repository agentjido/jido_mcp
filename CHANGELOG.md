# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Added `mcp.endpoint.default.set` and runtime endpoint lifecycle routes.
- Added endpoint unregistration and readiness APIs.
- Added an ExMCP migration guide and a frozen public API inventory.

### Changed

- Replaced Anubis with stable ExMCP `~> 1.0` for client and server protocol
  behavior.
- Changed the package version to `2.0.0` for the breaking protocol backend,
  server Plug, callback context, raw result, and legacy transport changes.
- Put `jido_mcp` in maintenance mode. New protocol work goes to ExMCP, new
  connector work goes to Jido Connect, and ACP lifecycle work goes to Jido
  Harness.
- MCP plugin allowlists now support `allowed_endpoints: :all`.
- Removed implicit MCP core to MCPAI runtime sync. Host applications now use
  plugin signals for lifecycle and sync.
- Endpoint calls now wait for ExMCP readiness before execution.
- `Jido.MCP.refresh_endpoint/1` now refreshes lifecycle only. It does not run
  `tools/list`.
- Removed MCPAI orchestration shims from `Jido.MCP`.

### Security

- Kept temporary Cowlib advisory exceptions for the reviewed Plug, Cowboy, and
  ExMCP call paths. Review them by 2026-09-12 or when a fixed Cowlib release is
  available.

## [0.1.1] - 2026-02-25

### Changed

- Switched `anubis_mcp` from a local path dependency to Hex (`~> 0.17.0`).
- Switched `jido` from a local path dependency to Hex (`~> 2.0`) so the package can be published on Hex.
- Updated release metadata in `mix.exs` (package files, maintainers, docs links, and release check alias).
- Updated `ex_doc` development dependency to `~> 0.40`.

<!-- changelog -->

## [v1.1.1](https://github.com/agentjido/jido_mcp/compare/v1.1.0...v1.1.1) (2026-08-10)




### Bug Fixes:

* deps: update Mint for CVE-2026-59249 by mikehostetler

## [v1.1.0](https://github.com/agentjido/jido_mcp/compare/v1.0.0...v1.1.0) (2026-06-11)




### Features:

* harden MCP JSON Schema support by mikehostetler

### Bug Fixes:

* bump anubis_mcp to 1.6.2 (#31) by mikehostetler

* clean Elixir 1.20 compile warnings by mikehostetler

* accept root schema metadata for MCP tools (#22) by Julien

* stabilize dependency baseline by mikehostetler

* support nullable anyOf tool schemas by mikehostetler

* consume Peri nil-content fix by mikehostetler
