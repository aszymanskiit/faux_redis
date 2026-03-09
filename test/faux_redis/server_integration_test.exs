defmodule FauxRedis.ServerIntegrationTest do
  # async: false to avoid timeouts under Docker/CI when many servers run in parallel
  use FauxRedis.Case, async: false

  alias FauxRedis.RESP

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", port, [:binary, packet: :raw, active: false])

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
    # SET/GET use local ETS; INCR uses Server store, so "a" starts at 0 there → INCR returns 1
    assert [1, "1", "2"] == Enum.drop(responses, 2)
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
end
