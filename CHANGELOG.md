# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-10-19

### Added

- Sorted set commands `ZADD` (with `NX`, `XX`, `GT`, `LT`, `CH`), `ZRANGE`
  (with `REV`, `WITHSCORES`), `ZSCORE` and `ZREM` (`Store.zadd/4`,
  `Store.zrange/5`, `Store.zscore/3`, `Store.zrem/3` and server handlers).
- Lua scripting: `EVAL`, `EVALSHA`, `SCRIPT LOAD`, `SCRIPT EXISTS`,
  `SCRIPT FLUSH` (`FauxRedis.Script`, built on the pure-Erlang `luerl` VM;
  `redis.call` / `redis.pcall` run against the in-memory store).
- New runtime dependency: `luerl ~> 1.2`.
- Unit and integration tests for sorted set commands and Lua scripting.
- README sections documenting sorted set and scripting behaviour and limitations.

### Fixed

- `GET` / `MGET` no longer crash on keys holding a sorted set (return `nil`).

## [1.0.3] - 2026-06-12

### Added

- `SCARD` – set cardinality (`Store.scard/2` and server handler).
- Unit and integration tests for `SCARD` (including `WRONGTYPE` on non-set keys).
- README section documenting `SCARD` behaviour and limitations.

## [1.0.2] - 2026-06-12

### Fixed

- `SCAN` / `KEYS` `MATCH` now supports full Redis-style glob patterns (multiple
  `*`, `?`, character classes, escapes). Fixes patterns such as `*@*` that were
  previously ignored and returned no keys.

### Added

- `FauxRedis.Glob` – internal glob matcher shared by `Store.scan/3` and `KEYS`.
- Unit and integration tests for `MATCH` patterns and `SCAN` without `MATCH`.

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

