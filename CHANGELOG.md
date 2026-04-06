# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-04-07

### Fixed

- Compiler warnings (unused bindings in `Store.match_pattern?/2`, `Server` SCAN handler).
- Credo “nested too deep” in `Store.srem/3` and `Server.extract_scan_count/1` (small refactors).
- Dialyzer: `plt_add_apps: [:ex_unit]` and ignore patterns for ExUnit macro-expanded calls in `FauxRedis.Case`; Dialyzer clean with `ex_doc` only in `:dev`.
- Integration test “pipelining many commands” assertion aligned with Redis `INCR` semantics after `SET`.

### Changed

- **Hex / CI:** publish tarball with `MIX_ENV=prod` (`mix hex.publish package`), publish docs with `MIX_ENV=dev` (`mix hex.publish docs`) so `ex_doc` stays `only: :dev`.
- **Documentation (ExDoc):** `groups_for_modules` (API vs implementation), `source_ref` for GitHub links, fixed `@typedoc` link to `t:FauxRedis.response_spec` in `MockRule`, `FauxRedis` module doc lists `address/1`.

## [1.0.0] - 2026-04-06

### Changed

- First **stable** Hex release; public API aligned with 0.1.x.

## [0.1.0] - 2026-03-06

### Added

- Initial release of **FauxRedis** – a controllable dummy Redis server
  for integration testing (ejabberd/XMPP-friendly).
- RESP2 protocol implementation with parser and encoder.
- TCP server and per-connection processes with pipelining support.
- In-memory store supporting strings, hashes, sets, lists, TTLs and basic
  numeric operations.
- Mocking engine with stubs/expectations, sequential responses, delays,
  timeouts, connection closes, protocol errors and partial replies.
- Minimal pub/sub support (`PUBLISH`, `SUBSCRIBE`, `UNSUBSCRIBE`).
- ExUnit helper case template and example tests.
- GitHub Actions CI, Credo, formatter and dialyzer configuration.

