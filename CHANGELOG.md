# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

