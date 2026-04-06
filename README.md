# FauxRedis

[![CI](https://github.com/aszymanskiit/faux_redis/actions/workflows/ci.yml/badge.svg)](https://github.com/aszymanskiit/faux_redis/actions/workflows/ci.yml)

A controllable, Redis-compatible dummy server implemented in Elixir/OTP, designed
specifically for **integration testing**.

FauxRedis speaks the Redis RESP protocol over TCP, but exposes a rich
programmatic API for **stubbing, expectations and fault injection** – allowing
you to simulate everything from normal key-value operations to timeouts,
disconnects and protocol errors.

> This project is intentionally not a production Redis replacement. It is a
> **test tool** with predictable behaviour and powerful mocking.

## Name

**FauxRedis** – a short, memorable name for a fake Redis server aimed at
integration tests. Suggested GitHub repo: `faux_redis` (slug: `faux-redis`).


## Features

- **Real TCP server** speaking Redis/RESP on a configurable (or random) port.
- **Supports multiple simultaneous connections and pipelining.**
- **Extensible command dispatcher**, with built-in support for:
  - `PING`, `ECHO`, `AUTH`, `HELLO`, `SELECT`, `QUIT`, `INFO`, `CLIENT`, `COMMAND`
  - `GET`, `SET`, `DEL`, `EXISTS`, `EXPIRE`, `TTL`, `KEYS`, `SCAN`, `FLUSHALL`
  - `HGET`, `HSET`, `HGETALL`, `HMGET`, `HMSET`
  - `SADD`, `SMEMBERS`, `SREM`, `SISMEMBER`, `SSCAN`
  - `LPUSH`, `RPUSH`, `LPOP`, `RPOP`
  - `MGET`, `MSET`, `INCR`, `DECR`
  - `PUBLISH`, `SUBSCRIBE`, `UNSUBSCRIBE` (simplified)
- **Mock/stub engine**:
  - Match by command name, arguments, regex, custom predicate (`{:fn, fun}`), or connection id.
  - Define:
    - constant responses
    - callback functions (`{:fun, fn command -> response end}`)
    - delays (`{:delay, ms, response}`), timeouts (`:timeout`) and missing replies (`:no_reply`)
    - connection closes (`:close` or `{:close, response}`)
    - protocol errors (`{:protocol_error, bytes}`) and partial responses (`{:partial, [chunks]}`)
  - Sequential responses per rule.
  - Full call history for assertions.
- **Stateful in-memory store**:
  - Strings, hashes, sets, lists and TTLs (enough for most ejabberd/XMPP tests).
- **ExUnit helper** for quick integration in Elixir projects.
- Designed to be **fast to start**, good for **parallel test runs**.

## Installation

Add to your `mix.exs` dependencies.

```elixir
def deps do
  [
    {:faux_redis, "~> 1.0", only: :test}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Basic usage

You usually run FauxRedis as part of your test supervision tree or via the
provided ExUnit case template.

### Starting manually inside a test

Main options for `start_link/1`: `:port` (default `0` = random), `:mode` (`:mock_first`, `:stateful_only`, `:mock_only`), `:name` (registered name), `:ip` (bind address, default `{127,0,0,1}`), `:require_auth?`, `:password`.

```elixir
test "simple PING/ECHO with random port" do
  {:ok, server} = FauxRedis.start_link(port: 0, mode: :mock_first)

  port = FauxRedis.port(server)

  {:ok, socket} =
    :gen_tcp.connect('localhost', port, [:binary, packet: :raw, active: false])

  payload =
    [
      ["PING"],
      ["ECHO", "hi"]
    ]
    |> Enum.map(&FauxRedis.RESP.encode/1)
    |> IO.iodata_to_binary()

  :ok = :gen_tcp.send(socket, payload)
  {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)

  assert {:ok, "PONG"} = FauxRedis.RESP.decode_exactly(data |> String.split_at(8) |> elem(0))

  :gen_tcp.close(socket)
  FauxRedis.stop(server)
end
```

### Using the ExUnit helper

The library ships with `FauxRedis.Case`, which starts an isolated server per
test and injects `redis_server` and `redis_port` into the test context. It also
imports convenience `stub/3` and `expect/3` that take the context map as the first
argument (they delegate to `FauxRedis.stub/3` / `FauxRedis.expect/3`).

```elixir
defmodule MyApp.RedisIntegrationTest do
  use FauxRedis.Case, async: true

  test "basic interaction", %{redis_server: server, redis_port: port} do
    {:ok, _rule} = FauxRedis.stub(server, :get, "value")

    {:ok, socket} =
      :gen_tcp.connect('localhost', port, [:binary, packet: :raw, active: false])

    payload =
      ["GET", "foo"]
      |> FauxRedis.RESP.encode()
      |> IO.iodata_to_binary()

    :ok = :gen_tcp.send(socket, payload)
    {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
    assert {:ok, "value"} = FauxRedis.RESP.decode_exactly(data)

    :gen_tcp.close(socket)
  end

  test "using context helpers", %{redis_port: port} = ctx do
    {:ok, _rule} = stub(ctx, :ping, "PONG")
    # ...
  end
end
```

## Mocking API

The public API lives in the `FauxRedis` module:

- `start_link/1`, `child_spec/1`
- `stub/2` (keyword list: `matcher`, `respond`, `conn_id`/`conn_ids`, `max_calls`) and `stub/3` (short form)
- `expect/3`
- `calls/1`
- `reset!/1`
- `port/1`, `address/1` (host is always `"127.0.0.1"` in the returned tuple; bind address is set via `:ip` in `start_link/1`)
- `stop/1`

Low-level RESP helpers: `FauxRedis.RESP` (`encode/1`, `decode/1`, `decode_exactly/1`, …) for building or parsing wire payloads in tests.

### Stubbing a single command

```elixir
{:ok, server} = FauxRedis.start_link(port: 0)

# Always respond to GET foo with "bar"
{:ok, _rule} =
  FauxRedis.stub(server, {:command, :get, ["foo"]}, "bar")
```

### Sequential responses

```elixir
# First GET foo -> "one"
# Second GET foo -> "two"
# Third and subsequent GET foo -> nil
{:ok, _rule} =
  FauxRedis.stub(server, :get, ["one", "two", nil])
```

### Fault injection

```elixir
# PING:
#   1st call -> reply "SLOW" after 500ms
#   2nd call -> no reply (:timeout or :no_reply)
#   3rd call -> close connection
{:ok, _rule} =
  FauxRedis.stub(server, :ping, [
    {:delay, 500, "SLOW"},
    :timeout,
    :close
  ])
```

### Matching by regex, arguments and connection id

```elixir
# Match any GET whose key starts with "session:"
{:ok, _rule} =
  FauxRedis.stub(server, {:command, :get, [~r/^session:/]}, fn cmd ->
    {:error, "ERR sessions disabled in tests"}
  end)
```

You can also restrict rules to specific connections via `:conn_id` or
`:conn_ids` options when calling `stub/2`/`expect/3` (see moduledoc of
`FauxRedis.MockRule` for details).

### Inspecting call history

```elixir
calls = FauxRedis.calls(server)

assert [
         %{
           name: "GET",
           args: ["foo"],
           conn_id: _,
           db: 0,
           timestamp: _,
           rule_id: _,
           action: _
         }
       ] = calls
```

### Resetting between tests

```elixir
FauxRedis.reset!(server)
```

This clears:

- all keys and TTLs
- all mock rules and expectations
- call history
- auth and pub/sub state

## Using with ejabberd / XMPP

FauxRedis is designed to play nicely with typical Redis clients used by
ejabberd and other XMPP systems:

- Start the server on a **random port** (the default when passing `port: 0`).
- Ask FauxRedis for the address and use it in ejabberd config:

  ```elixir
  {:ok, server} = FauxRedis.start_link(port: 0)
  {"127.0.0.1", port} = FauxRedis.address(server)
  ```

  Then, in your `ejabberd.yml` test configuration (or its template):

  ```yaml
  redis:
    server: "127.0.0.1"
    port:   <PORT_FROM_FauxRedis.address/1>
  ```

  Typically you will inject the port via environment variable or a generated
  config file in your test harness.

- Use the mocking API to simulate:
  - normal key/value behaviour
  - authentication success/failure via `AUTH`
  - slow Redis (`{:delay, ms, inner}`)
  - completely unavailable Redis (`:timeout` / `:close`)
  - protocol-level weirdness (`{:protocol_error, bytes}`, `{:partial, chunks}`)

Because the server is a normal OTP process, you can run **multiple instances
in a single test suite** to simulate multiple Redis backends if necessary.

## Architectural overview

- `FauxRedis.Application` – starts a `Registry` for optional server naming.
- `FauxRedis.Command` – parsed command struct (name, args, connection id, DB, …).
- `FauxRedis.Server` – GenServer owning:
  - TCP listener
  - connection registry
  - in-memory store
  - mock rules and call history
  - minimal pub/sub state
- `FauxRedis.Connection` – per-socket process:
  - buffers incoming bytes
  - decodes RESP frames and pipelines
  - applies response specifications (delays, closes, partials, etc.)
- `FauxRedis.RESP` – RESP2 encoder/decoder.
- `FauxRedis.Store` – in-memory Redis-like store.
- `FauxRedis.MockRule` / `MockEngine` – rule representation and evaluation.
- `FauxRedis.Case` – ExUnit helper case template.

## Limitations vs real Redis

FauxRedis is **not** a full Redis implementation. Notable limitations:

- Only a subset of commands is implemented; behaviour of `SCAN`, `KEYS`, `SSCAN`, etc. follows this implementation, not every edge case of Redis.
- Pub/sub semantics are simplified:
  - `SUBSCRIBE`/`UNSUBSCRIBE` do not switch the connection into a dedicated
    pub/sub mode; they manage an internal subscription table and return simple
    acknowledgements.
  - Messages are pushed as RESP arrays `["message", channel, payload]`, but not
    all edge cases of real Redis pub/sub are reproduced.
- Persistence, replication, clustering and scripting are **not** supported.
- Performance characteristics are tuned for tests, not for production loads.

If you need more real-world behaviour, consider using a real Redis instance for
system tests and FauxRedis for **fine-grained, deterministic integration
tests** and fault injection.

## Running locally

After cloning the repository:

```bash
mix deps.get
mix test
```

The codebase is compatible with **OTP 24 and newer**; the CI matrix runs tests
on OTP 24, 25 and 26 to keep this guarantee.

## License

This project is licensed under the MIT License – see the `LICENSE` file.

