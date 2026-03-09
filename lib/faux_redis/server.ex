defmodule FauxRedis.Server do
  @moduledoc """
  OTP process that owns the TCP listener, manages connection processes, holds
  the in-memory store and mock rules, and implements Redis command semantics.

  Users normally interact with this module indirectly via the `FauxRedis`
  facade, but the functions here are public to make supervision and advanced
  control easier when needed.
  """

  use GenServer

  require Logger
  alias FauxRedis.{Command, MockEngine, MockRule, Store}

  @typedoc "Internal server mode."
  @type mode :: :mock_first | :stateful_only | :mock_only

  @typedoc "Server state kept in the GenServer."
  @type t :: %__MODULE__{
          listener: port() | nil,
          port: non_neg_integer() | nil,
          mode: mode(),
          require_auth?: boolean(),
          password: binary() | nil,
          rules: [MockRule.t()],
          store: Store.t(),
          calls: [FauxRedis.call_record()],
          max_calls: pos_integer(),
          next_conn_id: non_neg_integer(),
          connections: %{non_neg_integer() => pid()},
          authed: MapSet.t(non_neg_integer()),
          subscriptions: %{pid() => MapSet.t(binary())},
          channels: %{binary() => MapSet.t(pid())},
          ets_kv: term()
        }

  defstruct listener: nil,
            port: nil,
            mode: :mock_first,
            require_auth?: false,
            password: nil,
            rules: [],
            store: Store.new(),
            calls: [],
            max_calls: 1_000,
            next_conn_id: 1,
            connections: %{},
            authed: MapSet.new(),
            subscriptions: %{},
            channels: %{},
            ets_kv: nil

  ## Public API

  @doc """
  Starts a new server process.

  Options:

    * `:port` – TCP port to listen on (0 = random free port, default)
    * `:mode` – `:mock_first` (default), `:stateful_only`, or `:mock_only`
    * `:require_auth?` – whether AUTH is required before most commands
    * `:password` – the expected password for AUTH
    * `:name` – optional registered name (e.g. via `Registry`)
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name_opt =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, name_opt)
  end

  @doc """
  Returns a child spec suitable for supervision trees.
  """
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc """
  Registers a new stub or expectation rule.

  This is the backing implementation for `FauxRedis.stub/2`, `stub/3`
  and `FauxRedis.expect/3`.
  """
  @spec add_rule(GenServer.server(), MockRule.kind(), Keyword.t()) ::
          {:ok, reference()}
  def add_rule(server, kind, opts) when kind in [:stub, :expect] do
    GenServer.call(server, {:add_rule, kind, opts})
  end

  @doc """
  Returns the list of recorded calls, ordered from oldest to newest.
  """
  @spec calls(GenServer.server()) :: [FauxRedis.call_record()]
  def calls(server) do
    GenServer.call(server, :calls)
  end

  @doc """
  Resets the server state (store, rules, history, auth, pub/sub).
  """
  @spec reset!(GenServer.server()) :: :ok
  def reset!(server) do
    GenServer.call(server, :reset)
  end

  @doc """
  Returns the TCP port the server is listening on.
  """
  @spec port(GenServer.server()) :: non_neg_integer()
  def port(server) do
    GenServer.call(server, :port)
  end

  ## GenServer callbacks

  @impl GenServer
  def init(opts) do
    mode = Keyword.get(opts, :mode, :mock_first)

    unless mode in [:mock_first, :stateful_only, :mock_only] do
      raise ArgumentError, "invalid :mode option: #{inspect(mode)}"
    end

    require_auth? = Keyword.get(opts, :require_auth?, false)
    password = Keyword.get(opts, :password)
    port = Keyword.get(opts, :port, 0)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    {:ok, listener} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: ip
      ])

    {:ok, {_addr, actual_port}} = :inet.sockname(listener)

    # ETS for GET/SET so Connection can serve them locally (no Server queue).
    ets_kv = :ets.new(:faux_redis_kv, [:set, :public])

    conn_id_counter = :counters.new(1, [:atomics])
    :counters.put(conn_id_counter, 1, 1)

    state = %__MODULE__{
      mode: mode,
      require_auth?: require_auth?,
      password: password,
      listener: listener,
      port: actual_port,
      ets_kv: ets_kv
    }

    server = self()

    spawn_link(fn ->
      accept_loop(listener, server, conn_id_counter, state.mode, ets_kv)
      :ok
    end)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:allocate_connection_id, _from, state) do
    conn_id = state.next_conn_id
    {:reply, conn_id, %{state | next_conn_id: conn_id + 1}}
  end

  @impl GenServer
  def handle_call({:register_connection, pid}, _from, state) do
    conn_id = state.next_conn_id
    connections = Map.put(state.connections, conn_id, pid)
    state = %{state | next_conn_id: conn_id + 1, connections: connections}

    reply = %{
      conn_id: conn_id,
      port: state.port,
      mode: state.mode,
      require_auth?: state.require_auth?,
      password: state.password
    }

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call({:add_rule, kind, opts}, _from, state) do
    rule = MockRule.build(kind, opts)
    {:reply, {:ok, rule.id}, %{state | rules: [rule | state.rules]}}
  end

  @impl GenServer
  def handle_call(:calls, _from, state) do
    {:reply, Enum.reverse(state.calls), state}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    if state.ets_kv do
      :ets.delete_all_objects(state.ets_kv)
    end

    new_state = %{
      state
      | rules: [],
        store: Store.new(),
        calls: [],
        authed: MapSet.new(),
        subscriptions: %{},
        channels: %{}
    }

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  @impl GenServer
  def handle_call(:get_mode, _from, state) do
    {:reply, state.mode, state}
  end

  # Command handling via cast so the Server is never blocked by a long queue of calls;
  # each Connection blocks in receive(), so many connections do not block the Server.
  @impl GenServer
  def handle_cast({:command, conn_pid, ref, conn_id, db, %Command{} = command}, state) do
    Logger.debug(
      "[FauxRedis.Server] port=#{state.port} conn_id=#{conn_id} command=#{command.name}"
    )

    {resp_spec, new_state, new_db, rule_id} =
      case state.mode do
        :stateful_only ->
          {resp, st, new_db} = handle_builtin(conn_id, db, command, state)
          {resp, st, new_db, nil}

        mode when mode in [:mock_first, :mock_only] ->
          result = MockEngine.apply(state.rules, command, mode, fn -> :builtin end)
          state1 = %{state | rules: result.rules}

          case result.response do
            :builtin ->
              {resp, st, new_db} = handle_builtin(conn_id, db, command, state1)
              {resp, st, new_db, nil}

            resp ->
              {resp, state1, db, result.rule_id}
          end
      end

    call_record = build_call_record(conn_id, db, command, resp_spec, rule_id)
    calls = [call_record | state.calls] |> Enum.take(state.max_calls)
    next_state = %{new_state | calls: calls}

    send(conn_pid, {:command_reply, ref, {resp_spec, new_db}})

    Logger.debug(
      "[FauxRedis.Server] port=#{state.port} conn_id=#{conn_id} replying for #{command.name}"
    )

    {:noreply, next_state}
  end

  @impl GenServer
  def handle_cast({:register_connection_pid, conn_id, pid}, state) do
    connections = Map.put(state.connections, conn_id, pid)
    next = max(state.next_conn_id, conn_id + 1)
    {:noreply, %{state | connections: connections, next_conn_id: next}}
  end

  @impl GenServer
  def handle_cast({:connection_closed, conn_id, pid}, state) do
    connections =
      case Map.get(state.connections, conn_id) do
        ^pid -> Map.delete(state.connections, conn_id)
        _ -> state.connections
      end

    authed = MapSet.delete(state.authed, conn_id)

    {subscriptions, channels} =
      case Map.pop(state.subscriptions, pid) do
        {nil, subs} ->
          {subs, state.channels}

        {channels_for_pid, subs} ->
          channels = remove_pid_from_channels(state.channels, channels_for_pid, pid)
          {subs, channels}
      end

    state = %{
      state
      | connections: connections,
        authed: authed,
        subscriptions: subscriptions,
        channels: channels
    }

    {:noreply, state}
  end

  defp remove_pid_from_channels(channels, channels_for_pid, pid) do
    Enum.reduce(channels_for_pid, channels, fn ch, acc ->
      case Map.get(acc, ch) do
        nil -> acc
        set -> Map.put(acc, ch, MapSet.delete(set, pid))
      end
    end)
  end

  defp build_call_record(conn_id, db, command, resp_spec, rule_id) do
    %{
      conn_id: conn_id,
      name: command.name,
      args: command.args,
      db: db,
      timestamp: command.timestamp,
      rule_id: rule_id,
      action: resp_spec
    }
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.listener do
      :gen_tcp.close(state.listener)
    end

    :ok
  end

  ## Accept loop
  #
  # Use conn_id_counter so we never block on the Server (client would otherwise timeout).
  # Pass socket to Connection only after controlling_process so client data goes to Connection.

  @spec accept_loop(port(), pid(), :counters.counters_ref(), mode(), term()) :: :ok
  defp accept_loop(listener, server, conn_id_counter, mode, ets_kv) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        conn_id = :counters.get(conn_id_counter, 1)
        :ok = :counters.add(conn_id_counter, 1, 1)
        {:ok, pid} = FauxRedis.Connection.start_link(server, conn_id)
        :ok = :gen_tcp.controlling_process(socket, pid)
        GenServer.cast(server, {:register_connection_pid, conn_id, pid})
        send(pid, {:socket, socket, mode, ets_kv})
        accept_loop(listener, server, conn_id_counter, mode, ets_kv)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        exit(:accept_failed)
    end
  end

  ## Built-in command semantics

  @spec handle_builtin(non_neg_integer(), non_neg_integer(), Command.t(), t()) ::
          {term(), t(), non_neg_integer()}
  defp handle_builtin(conn_id, db, %Command{name: name} = cmd, state) do
    if state.require_auth? and not authed?(state, conn_id) and name not in ["AUTH", "HELLO"] do
      {{:error, "NOAUTH Authentication required"}, state, db}
    else
      do_handle(conn_id, db, cmd, state)
    end
  end

  defp authed?(state, conn_id), do: MapSet.member?(state.authed, conn_id)

  @spec do_handle(non_neg_integer(), non_neg_integer(), Command.t(), t()) ::
          {term(), t(), non_neg_integer()}
  defp do_handle(_conn_id, db, %Command{name: "PING", args: []}, state) do
    {"PONG", state, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "PING", args: [msg]}, state) do
    {msg, state, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "ECHO", args: [msg]}, state) do
    {msg, state, db}
  end

  defp do_handle(conn_id, db, %Command{name: "AUTH", args: [password]}, state) do
    cond do
      state.password && password == state.password ->
        authed = MapSet.put(state.authed, conn_id)
        {:ok, %{state | authed: authed}, db}

      state.password && password != state.password ->
        {{:error, "ERR invalid password"}, state, db}

      true ->
        authed = MapSet.put(state.authed, conn_id)
        {:ok, %{state | authed: authed}, db}
    end
  end

  defp do_handle(_conn_id, db, %Command{name: "HELLO", args: ["3" | _]}, state) do
    # RESP3 handshake (e.g. Redix): return map-like list so client keeps connection open.
    info = [
      "server",
      "faux-redis",
      "version",
      "6.0.0",
      "proto",
      3,
      "id",
      0,
      "mode",
      Atom.to_string(state.mode),
      "role",
      "master"
    ]

    {info, state, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "HELLO"}, state) do
    info = [
      "server",
      "faux-redis",
      "proto",
      2,
      "id",
      "faux-redis",
      "mode",
      Atom.to_string(state.mode)
    ]

    {info, state, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "SELECT", args: [index]}, state) do
    case Integer.parse(index) do
      {i, ""} when i >= 0 ->
        {:ok, state, i}

      _ ->
        {{:error, "ERR invalid DB index"}, state, db}
    end
  end

  defp do_handle(_conn_id, db, %Command{name: "QUIT"}, state) do
    {{:close, :ok}, state, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "INFO"}, state) do
    payload = """
    # Server
    faux_redis:0.1.0

    # Clients
    connected_clients:#{map_size(state.connections)}
    """

    {payload, state, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "CLIENT"}, state) do
    # Minimal stub: accept any CLIENT command and respond OK.
    {:ok, state, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "COMMAND"}, state) do
    commands = [
      ["ping", 0],
      ["echo", 1],
      ["auth", 1],
      ["select", 1],
      ["get", 1],
      ["set", 2],
      ["del", -1]
    ]

    {commands, state, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "GET", args: [key]}, state) do
    {store, value} = Store.get(state.store, key)
    {value, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "SET", args: [key, value]}, state) do
    store = Store.set(state.store, key, value)
    {:ok, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "DEL", args: keys}, state) do
    {store, deleted} = Store.del(state.store, keys)
    {deleted, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "SCAN", args: [cursor | rest]}, state) do
    # For the purposes of FauxRedis we implement a simplified SCAN:
    #  * we ignore the incoming cursor and always return a full, single page
    #  * we respect a minimal subset of options used in our tests:
    #      SCAN cursor MATCH pattern COUNT n
    pattern = extract_scan_match(rest) || "*"
    count = extract_scan_count(rest) || 10

    {store, {next_cursor, keys}} = Store.scan(state.store, pattern, count)
    { [next_cursor, keys], %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "SSCAN", args: [key, cursor | _rest]}, state) do
    # returned member list; match that behaviour in a simplified form.
    {store, {next_cursor, members}} = Store.sscan(state.store, key, cursor, 10)
    { [next_cursor, members], %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "EXISTS", args: keys}, state) do
    {store, count} = Store.exists(state.store, keys)
    {count, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "EXPIRE", args: [key, seconds]}, state) do
    case Integer.parse(seconds) do
      {secs, ""} when secs > 0 ->
        {store, res} = Store.expire(state.store, key, secs)
        {res, %{state | store: store}, db}

      _ ->
        {0, state, db}
    end
  end

  defp do_handle(_conn_id, db, %Command{name: "TTL", args: [key]}, state) do
    {store, ttl} = Store.ttl(state.store, key)
    {ttl, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "HGET", args: [key, field]}, state) do
    {store, value} = Store.hget(state.store, key, field)
    {value, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "HSET", args: [key, field, value]}, state) do
    {store, res} = Store.hset(state.store, key, field, value)
    {res, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "HSET", args: [key | rest]}, state) do
    pairs = Enum.chunk_every(rest, 2)

    {store, added} =
      Enum.reduce(pairs, {state.store, 0}, fn
        [field, value], {st, acc} ->
          {st2, res} = Store.hset(st, key, field, value)
          {st2, acc + res}

        _odd, acc ->
          acc
      end)

    {added, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "HGETALL", args: [key]}, state) do
    {store, flat} = Store.hgetall(state.store, key)
    {flat, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "HMGET", args: [key | fields]}, state) do
    {store, _} = Store.hgetall(state.store, key)

    {_store, values} =
      Enum.reduce(fields, {store, []}, fn field, {st, acc} ->
        {st2, value} = Store.hget(st, key, field)
        {st2, acc ++ [value]}
      end)

    {values, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "HMSET", args: [key | rest]}, state) do
    pairs = Enum.chunk_every(rest, 2)

    store =
      Enum.reduce(pairs, state.store, fn
        [field, value], st ->
          {st2, _} = Store.hset(st, key, field, value)
          st2

        _odd, st ->
          st
      end)

    {:ok, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "SADD", args: [key | members]}, state) do
    {store, added} = Store.sadd(state.store, key, members)
    {added, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "SMEMBERS", args: [key]}, state) do
    {store, members} = Store.smembers(state.store, key)
    {members, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "LPUSH", args: [key | values]}, state) do
    {store, len} = Store.lpush(state.store, key, values)
    {len, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "RPUSH", args: [key | values]}, state) do
    {store, len} = Store.rpush(state.store, key, values)
    {len, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "LPOP", args: [key]}, state) do
    {store, value} = Store.lpop(state.store, key)
    {value, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "RPOP", args: [key]}, state) do
    {store, value} = Store.rpop(state.store, key)
    {value, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "MGET", args: keys}, state) do
    {store, values} = Store.mget(state.store, keys)
    {values, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "MSET", args: kvs}, state) do
    pairs =
      kvs
      |> Enum.chunk_every(2)
      |> Enum.filter(fn chunk -> length(chunk) == 2 end)
      |> Enum.map(fn [k, v] -> {k, v} end)

    store = Store.mset(state.store, pairs)
    {:ok, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "INCR", args: [key]}, state) do
    {store, val} = Store.incr(state.store, key)
    {val, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "DECR", args: [key]}, state) do
    {store, val} = Store.decr(state.store, key)
    {val, %{state | store: store}, db}
  end

  defp do_handle(_conn_id, db, %Command{name: "PUBLISH", args: [channel, message]}, state) do
    subscribers = Map.get(state.channels, channel, MapSet.new())

    Enum.each(subscribers, fn pid ->
      send(pid, {:pubsub_message, channel, message})
    end)

    {MapSet.size(subscribers), state, db}
  end

  defp do_handle(conn_id, db, %Command{name: "SUBSCRIBE", args: channels}, state) do
    pid = Map.fetch!(state.connections, conn_id)
    existing = Map.get(state.subscriptions, pid, MapSet.new())

    new_channels = Enum.reduce(channels, existing, &MapSet.put(&2, &1))

    channels_map =
      Enum.reduce(channels, state.channels, fn ch, acc ->
        set = Map.get(acc, ch, MapSet.new())
        Map.put(acc, ch, MapSet.put(set, pid))
      end)

    subscriptions = Map.put(state.subscriptions, pid, new_channels)

    # Return list of subscribed channels as acknowledgement.
    {Enum.to_list(new_channels), %{state | subscriptions: subscriptions, channels: channels_map},
     db}
  end

  defp do_handle(conn_id, db, %Command{name: "UNSUBSCRIBE", args: channels}, state) do
    pid = Map.fetch!(state.connections, conn_id)
    existing = Map.get(state.subscriptions, pid, MapSet.new())

    {remaining, channels_map} =
      Enum.reduce(channels, {existing, state.channels}, fn ch, {set_acc, channels_acc} ->
        set_acc = MapSet.delete(set_acc, ch)

        channels_acc =
          case Map.get(channels_acc, ch) do
            nil -> channels_acc
            set -> Map.put(channels_acc, ch, MapSet.delete(set, pid))
          end

        {set_acc, channels_acc}
      end)

    subscriptions =
      if MapSet.size(remaining) == 0 do
        Map.delete(state.subscriptions, pid)
      else
        Map.put(state.subscriptions, pid, remaining)
      end

    {Enum.to_list(remaining), %{state | subscriptions: subscriptions, channels: channels_map}, db}
  end

  defp do_handle(_conn_id, db, _command, state) do
    {{:error, "ERR unknown command"}, state, db}
  end

  # Helpers for SCAN options (minimal subset used in tests)

  defp extract_scan_match(args) do
    case Enum.chunk_every(args, 2) do
      [] ->
        nil

      chunks ->
        chunks
        |> Enum.find_value(fn
          ["MATCH", pattern] -> pattern
          _ -> nil
        end)
    end
  end

  defp extract_scan_count(args) do
    case Enum.chunk_every(args, 2) do
      [] ->
        nil

      chunks ->
        chunks
        |> Enum.find_value(fn
          ["COUNT", n] ->
            case Integer.parse(n) do
              {int, ""} when int > 0 -> int
              _ -> nil
            end

          _ ->
            nil
        end)
    end
  end
end
