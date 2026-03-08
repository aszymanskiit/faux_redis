defmodule FauxRedis do
  @moduledoc """
  Public API for starting and controlling dummy Redis servers for integration tests.

  The main entry points are:

    * `start_link/1` – start a new Redis-compatible dummy server
    * `child_spec/1` – embed the server directly in your supervision tree
    * `stub/2` and `stub/3` – define stub rules for commands
    * `expect/3` – define expectation rules for commands
    * `calls/1` – fetch the history of executed commands
    * `reset!/1` – reset server state between tests
    * `port/1` – get the TCP port the server is listening on
    * `stop/1` – stop the server

  See the project README for more detailed examples.
  """

  @typedoc "A server reference; can be a PID or a registered name."
  @type server :: GenServer.server()

  @typedoc "A Redis command name, case-insensitive."
  @type command_name :: String.t() | atom()

  @typedoc """
  Matcher used to select which commands should be affected by a stub/expectation.

    * a simple command name (string or atom), e.g. `\"GET\"` or `:get`
    * `{:command, name, args_pattern}` where `args_pattern` is a list of:
      * exact binary values
      * `:any` wildcard
      * `~r/.../` regular expressions
    * `{:fn, fun}` – predicate function `fun.(command) :: boolean`
  """
  @type matcher ::
          command_name()
          | {:command, command_name(), [binary() | :any | Regex.t()]}
          | {:fn, (FauxRedis.Command.t() -> boolean())}

  @typedoc """
  Response specification used by stubs and expectations.

  Supported forms:

    * any plain value that can be encoded as RESP:
      * binary (bulk string)
      * integer
      * `nil` (null bulk string)
      * list (arrays)
      * `{:error, message}` (error reply)
      * `:ok` (simple string \"OK\")
    * `{:delay, ms, inner}` – delay sending `inner` by `ms` milliseconds
    * `:timeout` or `:no_reply` – do not send any reply
    * `:close` – immediately close the TCP connection
    * `{:close, inner}` – send `inner` then close the connection
    * `{:protocol_error, binary}` – send raw invalid bytes
    * `{:partial, [iodata()]}` – send raw chunks as-is, one by one
    * `{:fun, fun}` – callback `fun.(command) :: response_spec`
    * a non-empty list of response specs – used sequentially per matcher
  """
  @type response_spec ::
          term()
          | {:delay, non_neg_integer(), response_spec()}
          | :timeout
          | :no_reply
          | :close
          | {:close, response_spec()}
          | {:protocol_error, iodata()}
          | {:partial, [iodata()]}
          | {:fun, (FauxRedis.Command.t() -> response_spec())}
          | [response_spec()]

  @typedoc """
  A recorded command call, suitable for assertions in tests.
  """
  @type call_record :: %{
          conn_id: non_neg_integer(),
          name: String.t(),
          args: [binary()],
          db: non_neg_integer(),
          timestamp: integer(),
          rule_id: reference() | nil,
          action: term()
        }

  @doc """
  Starts a new dummy Redis server.

  Options:

    * `:port` – TCP port to listen on (defaults to `0`, meaning a random free port)
    * `:mode` – one of:
      * `:mock_first` (default) – try mock rules first, fall back to built-in semantics
      * `:stateful_only` – ignore mock rules, act as a simple in-memory Redis
      * `:mock_only` – only apply mock rules, unknown commands are errors
    * `:name` – optional registered name (via `Registry.FauxRedis.ServerRegistry`)
    * `:require_auth?` – whether connections must AUTH before using the server (default: `false`)
    * `:password` – expected password for AUTH (only meaningful when `:require_auth?` is `true`)
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    FauxRedis.Server.start_link(opts)
  end

  @doc """
  Returns a `child_spec/1` suitable for embedding the server under a supervisor.
  """
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    FauxRedis.Server.child_spec(opts)
  end

  @doc """
  Adds a stub rule using an options keyword list.

  This is the most flexible form and supports all fields of `FauxRedis.MockRule`.

  Basic usage:

      {:ok, rule_id} =
        FauxRedis.stub(server,
          matcher: :get,
          respond: \"bar\"
        )
  """
  @spec stub(server(), Keyword.t()) :: {:ok, reference()}
  def stub(server, opts) when is_list(opts) do
    FauxRedis.Server.add_rule(server, :stub, opts)
  end

  @doc """
  Convenience stub form: `stub(server, matcher, response_spec)`.

  Examples:

      # Always return \"bar\" for any GET
      FauxRedis.stub(server, :get, \"bar\")

      # Sequential responses for GET
      FauxRedis.stub(server, :get, [\"one\", \"two\", nil])
  """
  @spec stub(server(), matcher(), response_spec()) :: {:ok, reference()}
  def stub(server, matcher, response_spec) do
    FauxRedis.Server.add_rule(server, :stub, matcher: matcher, respond: response_spec)
  end

  @doc """
  Adds an expectation rule.

  Semantics are the same as for `stub/3`, but expectations are intended to be
  asserted via `calls/1` in your tests. The engine will keep track of how many
  times each expectation was used.
  """
  @spec expect(server(), matcher(), response_spec()) :: {:ok, reference()}
  def expect(server, matcher, response_spec) do
    FauxRedis.Server.add_rule(server, :expect, matcher: matcher, respond: response_spec)
  end

  @doc """
  Returns the list of all command calls observed by a server.

  The records are ordered by time and include information that is useful for
  assertions in tests (connection id, DB index, matched rule id, etc.).
  """
  @spec calls(server()) :: [call_record()]
  def calls(server) do
    FauxRedis.Server.calls(server)
  end

  @doc """
  Resets the server state:

    * clears all keys and data structures
    * clears TTLs
    * clears all mock rules and expectations
    * clears call history
  """
  @spec reset!(server()) :: :ok
  def reset!(server) do
    FauxRedis.Server.reset!(server)
  end

  @doc """
  Returns the TCP port the server is currently listening on.
  """
  @spec port(server()) :: non_neg_integer()
  def port(server) do
    FauxRedis.Server.port(server)
  end

  @doc """
  Returns `{host, port}` for pointing external systems (for example ejabberd)
  at this FauxRedis instance.

  By default the server binds to `127.0.0.1`, so the host is always
  `"127.0.0.1"` unless you override the `:ip` option when starting the
  server and manage host/port mapping yourself (e.g. via Docker).
  """
  @spec address(server()) :: {String.t(), non_neg_integer()}
  def address(server) do
    {"127.0.0.1", port(server)}
  end

  @doc """
  Stops the server gracefully.
  """
  @spec stop(server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end
end
