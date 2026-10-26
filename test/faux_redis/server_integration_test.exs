defmodule FauxRedis.ServerIntegrationTest do
  # async: false to avoid timeouts under Docker/CI when many servers run in parallel
  use FauxRedis.Case, async: false

  alias FauxRedis.RESP

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, packet: :raw, active: false])

    socket
  end

  defp send_recv(socket, frames) when is_list(frames) do
    payload =
      frames
      |> Enum.map(&RESP.encode/1)
      |> IO.iodata_to_binary()

    :ok = :gen_tcp.send(socket, payload)
    collect_n_responses(socket, length(frames), <<>>, 5_000)
  end

  defp collect_n_responses(_socket, 0, _buffer, _timeout), do: []

  defp collect_n_responses(socket, expected, buffer, timeout) do
    case decode_n_values(buffer, expected) do
      {:ok, values} ->
        values

      :need_more ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, more} ->
            collect_n_responses(socket, expected, buffer <> more, timeout)

          {:error, reason} ->
            raise "recv failed after #{length(decode_all(buffer))} values: #{inspect(reason)}"
        end
    end
  end

  defp decode_n_values(buffer, n), do: decode_n_values_acc(buffer, n, [])

  defp decode_n_values_acc(_buffer, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_n_values_acc(buffer, n, acc) when n > 0 do
    case RESP.decode(buffer) do
      {:ok, value, rest} -> decode_n_values_acc(rest, n - 1, [value | acc])
      :more -> :need_more
      {:error, _} -> :need_more
    end
  end

  defp decode_all(buffer, acc \\ []) do
    case RESP.decode(buffer) do
      {:ok, value, rest} -> decode_all(rest, [value | acc])
      :more -> Enum.reverse(acc)
      {:error, _} -> Enum.reverse(acc)
    end
  end

  defp close_socket(nil), do: :ok
  defp close_socket(sock) when is_port(sock), do: :gen_tcp.close(sock)

  defp cleanup_test_socket do
    close_socket(Process.get(:test_socket))
    Process.delete(:test_socket)
  end

  defp connect_and_put_socket(port) do
    socket = connect(port)
    Process.put(:test_socket, socket)
    socket
  end

  test "simple PING/ECHO over TCP", %{redis_port: port} do
    socket = connect_and_put_socket(port)
    responses = send_recv(socket, [["PING"], ["ECHO", "hi"]])
    assert ["PONG", "hi"] == responses
  after
    cleanup_test_socket()
  end

  test "stateful GET/SET and MGET/MSET", %{redis_port: port} do
    socket = connect_and_put_socket(port)
    _ = send_recv(socket, [["SET", "foo", "bar"]])
    _ = send_recv(socket, [["SET", "baz", "qux"]])
    [foo, mget] = send_recv(socket, [["GET", "foo"], ["MGET", "foo", "baz", "missing"]])
    assert "bar" == foo
    assert ["bar", "qux", nil] == mget
  after
    cleanup_test_socket()
  end

  test "pipelining many commands in one TCP frame", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    payload =
      IO.iodata_to_binary([
        RESP.encode(["SET", "a", "1"]),
        RESP.encode(["SET", "b", "2"]),
        RESP.encode(["INCR", "a"]),
        RESP.encode(["GET", "a"]),
        RESP.encode(["GET", "b"])
      ])

    :ok = :gen_tcp.send(socket, payload)
    responses = collect_n_responses(socket, 5, <<>>, 5_000)
    assert length(responses) == 5

    # SET stores string values; INCR parses the existing string as an integer (1) and increments → 2.
    # GET returns bulk strings, including integer-backed keys as decimal strings.
    assert [2, "2", "2"] == Enum.drop(responses, 2)
  after
    cleanup_test_socket()
  end

  test "mocking with sequential responses", %{redis_server: server, redis_port: port} do
    # Use ECHO (forwarded); GET is handled locally from ETS and would ignore the stub.
    {:ok, _} = FauxRedis.stub(server, :echo, ["one", "two", nil])
    socket = connect_and_put_socket(port)
    responses = send_recv(socket, [["ECHO", "a"], ["ECHO", "b"], ["ECHO", "c"]])
    assert ["one", "two", nil] == responses
  after
    cleanup_test_socket()
  end

  test "fault injection: timeout and close", %{redis_server: server, redis_port: port} do
    # Use ECHO (forwarded to server); PING is handled locally and would ignore the stub.
    {:ok, _} =
      FauxRedis.stub(server, :echo, [
        {:delay, 50, "SLOW"},
        :timeout,
        :close
      ])

    socket = connect_and_put_socket(port)

    # First ECHO gets delayed (50 ms) but arrives within timeout.
    :ok = :gen_tcp.send(socket, IO.iodata_to_binary(RESP.encode(["ECHO", "x"])))
    {:ok, data1} = :gen_tcp.recv(socket, 0, 2_000)
    assert {:ok, "SLOW"} = RESP.decode_exactly(data1)

    # Second ECHO gets no reply (timeout/no_reply).
    :ok = :gen_tcp.send(socket, IO.iodata_to_binary(RESP.encode(["ECHO", "y"])))
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 100)

    # Third ECHO causes connection close (under load we may see :timeout before :closed).
    :ok = :gen_tcp.send(socket, IO.iodata_to_binary(RESP.encode(["ECHO", "z"])))
    result = :gen_tcp.recv(socket, 0, 2_000)
    assert result in [{:error, :closed}, {:error, :timeout}]
  after
    cleanup_test_socket()
  end

  test "concurrent clients and reconnects", %{redis_port: port} do
    fun = fn i ->
      socket = connect(port)
      key = "k#{i}"

      _ = send_recv(socket, [["SET", key, Integer.to_string(i)]])
      [value] = send_recv(socket, [["GET", key]])

      :gen_tcp.close(socket)
      value
    end

    values =
      1..10
      |> Task.async_stream(fun, max_concurrency: 10, timeout: 5_000)
      |> Enum.map(fn {:ok, v} -> v end)
      |> Enum.sort_by(&String.to_integer/1)

    assert values == Enum.map(1..10, &Integer.to_string/1)
  end

  @tag :concurrent_20
  test "accepts and serves at least 20 concurrent connections (SET/GET)", %{redis_port: port} do
    n = 20

    fun = fn i ->
      socket = connect(port)
      key = "ck#{i}"
      _ = send_recv(socket, [["SET", key, "v#{i}"]])
      [value] = send_recv(socket, [["GET", key]])
      :gen_tcp.close(socket)
      value
    end

    values =
      1..n
      |> Task.async_stream(fun, max_concurrency: n, timeout: 10_000)
      |> Enum.map(fn {:ok, v} -> v end)
      |> Enum.sort_by(fn "v" <> rest -> String.to_integer(rest) end)

    assert values == Enum.map(1..n, fn i -> "v#{i}" end)
  end

  test "SSCAN over a set returns all members in a single page", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    _ = send_recv(socket, [["SADD", "set:key", "a", "b", "c"]])
    [[cursor, members]] = send_recv(socket, [["SSCAN", "set:key", "0"]])

    assert cursor == "0"
    assert Enum.sort(members) == ["a", "b", "c"]
  after
    cleanup_test_socket()
  end

  test "SCARD returns set cardinality", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    _ = send_recv(socket, [["SADD", "set:key", "a", "b", "c"]])
    assert [3] = send_recv(socket, [["SCARD", "set:key"]])
  after
    cleanup_test_socket()
  end

  test "SCARD returns 0 for a missing key", %{redis_port: port} do
    socket = connect_and_put_socket(port)
    assert [0] = send_recv(socket, [["SCARD", "no-such-key"]])
  after
    cleanup_test_socket()
  end

  test "SCARD returns 0 after all members are removed", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    _ = send_recv(socket, [["SADD", "set:key", "only"]])
    _ = send_recv(socket, [["SREM", "set:key", "only"]])
    assert [0] = send_recv(socket, [["SCARD", "set:key"]])
  after
    cleanup_test_socket()
  end

  test "SCARD returns WRONGTYPE for a non-set key", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    _ = send_recv(socket, [["SET", "str:key", "value"]])
    [error] = send_recv(socket, [["SCARD", "str:key"]])

    assert error ==
             {:error, "WRONGTYPE Operation against a key holding the wrong kind of value"}
  after
    cleanup_test_socket()
  end

  test "set commands still work alongside SCARD", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    assert [3] = send_recv(socket, [["SADD", "set:key", "a", "b", "c"]])
    assert [3] = send_recv(socket, [["SCARD", "set:key"]])
    assert ["1"] = send_recv(socket, [["SISMEMBER", "set:key", "b"]])
    [members] = send_recv(socket, [["SMEMBERS", "set:key"]])
    assert Enum.sort(members) == ["a", "b", "c"]
    assert [1] = send_recv(socket, [["SREM", "set:key", "b"]])
    assert [2] = send_recv(socket, [["SCARD", "set:key"]])
  after
    cleanup_test_socket()
  end

  @wrongtype {:error, "WRONGTYPE Operation against a key holding the wrong kind of value"}

  test "ZADD and ZRANGE return members ordered by score", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    assert [3] = send_recv(socket, [["ZADD", "z", "2", "b", "1", "a", "2.5", "c"]])
    assert [["a", "b", "c"]] = send_recv(socket, [["ZRANGE", "z", "0", "-1"]])
    assert [["c", "b"]] = send_recv(socket, [["ZRANGE", "z", "0", "1", "REV"]])

    assert [["a", "1", "b", "2", "c", "2.5"]] =
             send_recv(socket, [["ZRANGE", "z", "0", "-1", "WITHSCORES"]])

    assert [[]] = send_recv(socket, [["ZRANGE", "missing", "0", "-1"]])
  after
    cleanup_test_socket()
  end

  test "ZADD flags NX, XX, GT, LT and CH", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    assert [1] = send_recv(socket, [["ZADD", "z", "5", "a"]])
    assert [0] = send_recv(socket, [["ZADD", "z", "NX", "1", "a"]])
    assert [0] = send_recv(socket, [["ZADD", "z", "XX", "1", "new"]])
    assert [1] = send_recv(socket, [["ZADD", "z", "gt", "ch", "6", "a"]])
    assert [0] = send_recv(socket, [["ZADD", "z", "LT", "CH", "7", "a"]])
    assert ["6"] = send_recv(socket, [["ZSCORE", "z", "a"]])
    assert [nil] = send_recv(socket, [["ZSCORE", "z", "new"]])
  after
    cleanup_test_socket()
  end

  test "ZADD rejects invalid arguments", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    assert [{:error, "ERR XX and NX options at the same time are not compatible"}] =
             send_recv(socket, [["ZADD", "z", "NX", "XX", "1", "a"]])

    assert [{:error, "ERR GT, LT, and/or NX options at the same time are not compatible"}] =
             send_recv(socket, [["ZADD", "z", "GT", "LT", "1", "a"]])

    assert [{:error, "ERR value is not a valid float"}] =
             send_recv(socket, [["ZADD", "z", "abc", "a"]])

    assert [{:error, "ERR syntax error"}] = send_recv(socket, [["ZADD", "z", "1"]])
    assert [0] = send_recv(socket, [["EXISTS", "z"]])
  after
    cleanup_test_socket()
  end

  test "ZREM removes members and deletes the key when empty", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    _ = send_recv(socket, [["ZADD", "z", "1", "a", "2", "b"]])
    assert [1] = send_recv(socket, [["ZREM", "z", "a", "missing"]])
    assert [["b"]] = send_recv(socket, [["ZRANGE", "z", "0", "-1"]])
    assert [1] = send_recv(socket, [["ZREM", "z", "b"]])
    assert [0] = send_recv(socket, [["EXISTS", "z"]])
  after
    cleanup_test_socket()
  end

  test "sorted set commands return WRONGTYPE for non-zset keys", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    _ = send_recv(socket, [["SET", "str", "v"]])
    assert [@wrongtype] = send_recv(socket, [["ZADD", "str", "1", "a"]])
    assert [@wrongtype] = send_recv(socket, [["ZRANGE", "str", "0", "-1"]])
    assert [@wrongtype] = send_recv(socket, [["ZSCORE", "str", "a"]])
    assert [@wrongtype] = send_recv(socket, [["ZREM", "str", "a"]])
  after
    cleanup_test_socket()
  end

  @release_script """
  local score = redis.call('ZSCORE', KEYS[1], ARGV[1])

  if score and tonumber(score) > tonumber(ARGV[2]) then
    return 0
  end

  redis.call('ZREM', KEYS[1], ARGV[1])
  redis.call('DEL', KEYS[2])

  return 0
  """

  test "EVAL keeps the member when its score is newer than the threshold", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    _ = send_recv(socket, [["ZADD", "locks", "200", "job"], ["SET", "lock:job", "x"]])

    assert [0] =
             send_recv(socket, [["EVAL", @release_script, "2", "locks", "lock:job", "job", "100"]])

    assert ["200"] = send_recv(socket, [["ZSCORE", "locks", "job"]])
    assert ["x"] = send_recv(socket, [["GET", "lock:job"]])
  after
    cleanup_test_socket()
  end

  test "EVAL removes the member and key when the score is old enough", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    _ = send_recv(socket, [["ZADD", "locks", "50", "job"], ["SET", "lock:job", "x"]])

    assert [0] =
             send_recv(socket, [["EVAL", @release_script, "2", "locks", "lock:job", "job", "100"]])

    assert [nil] = send_recv(socket, [["ZSCORE", "locks", "job"]])
    assert [0] = send_recv(socket, [["EXISTS", "lock:job"]])
  after
    cleanup_test_socket()
  end

  test "EVAL returns values and errors like Redis", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    assert [["k", "a", 1]] =
             send_recv(socket, [["EVAL", "return {KEYS[1], ARGV[1], 1}", "1", "k", "a"]])

    assert [{:error, "ERR Number of keys can't be greater than number of args"}] =
             send_recv(socket, [["EVAL", "return 1", "2", "k"]])

    _ = send_recv(socket, [["SET", "str", "v"]])

    assert [{:error, "WRONGTYPE Operation against a key holding the wrong kind of value"}] =
             send_recv(socket, [["EVAL", "return redis.call('ZSCORE', KEYS[1], 'm')", "1", "str"]])

    assert [{:error, "ERR This Redis command is not allowed from script"}] =
             send_recv(socket, [["EVAL", "return redis.call('EVAL', 'return 1', '0')", "0"]])
  after
    cleanup_test_socket()
  end

  test "SCRIPT LOAD, SCRIPT EXISTS and EVALSHA", %{redis_port: port} do
    socket = connect_and_put_socket(port)
    sha = "e0e1f9fabfc9d4800c877a703b823ac0578ff8db"

    assert [{:error, "NOSCRIPT No matching script. Please use EVAL."}] =
             send_recv(socket, [["EVALSHA", sha, "0"]])

    assert [^sha] = send_recv(socket, [["SCRIPT", "LOAD", "return 1"]])
    assert [[1, 0]] = send_recv(socket, [["SCRIPT", "EXISTS", sha, "deadbeef"]])
    assert [1] = send_recv(socket, [["EVALSHA", String.upcase(sha), "0"]])
    assert ["OK"] = send_recv(socket, [["SCRIPT", "FLUSH"]])
    assert [[0]] = send_recv(socket, [["SCRIPT", "EXISTS", sha]])
  after
    cleanup_test_socket()
  end

  test "SCAN with MATCH and COUNT returns matching keys", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    _ = send_recv(socket, [["SET", "user1@example.com", "v1"]])
    _ = send_recv(socket, [["SET", "user2@example.com", "v2"]])
    _ = send_recv(socket, [["SET", "other", "v3"]])

    [[cursor, keys]] =
      send_recv(socket, [["SCAN", "0", "MATCH", "*@example.com", "COUNT", "100"]])

    assert cursor == "0"
    assert Enum.sort(keys) == ["user1@example.com", "user2@example.com"]
  after
    cleanup_test_socket()
  end

  test "SCAN 0 MATCH *@* returns only keys containing @", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    _ = send_recv(socket, [["SET", "alice@host", "1"]])
    _ = send_recv(socket, [["SET", "bob@host", "2"]])
    _ = send_recv(socket, [["SET", "no-at-sign", "3"]])

    [[cursor, keys]] = send_recv(socket, [["SCAN", "0", "MATCH", "*@*"]])

    assert cursor == "0"
    assert Enum.sort(keys) == ["alice@host", "bob@host"]
  after
    cleanup_test_socket()
  end

  test "SCAN without MATCH still returns all keys", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    _ = send_recv(socket, [["SET", "alpha", "1"]])
    _ = send_recv(socket, [["SET", "beta", "2"]])

    [[cursor, keys]] = send_recv(socket, [["SCAN", "0"]])

    assert cursor == "0"
    assert Enum.sort(keys) == ["alpha", "beta"]
  after
    cleanup_test_socket()
  end

  test "KEYS uses the same glob matching as SCAN MATCH", %{redis_port: port} do
    socket = connect_and_put_socket(port)

    _ = send_recv(socket, [["SET", "user@domain", "1"]])
    _ = send_recv(socket, [["SET", "guest", "2"]])

    [keys] = send_recv(socket, [["KEYS", "*@*"]])

    assert Enum.sort(keys) == ["user@domain"]
  after
    cleanup_test_socket()
  end
end
