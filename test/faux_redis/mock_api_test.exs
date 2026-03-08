defmodule FauxRedis.MockApiTest do
  use FauxRedis.Case, async: true

  # Use ECHO (forwarded to server); GET/PING are handled locally in Connection and never recorded.
  test "stub with matcher and response", %{redis_server: server} do
    {:ok, _} =
      FauxRedis.stub(server, {:command, :echo, ["foo"]}, "bar")

    calls_before = FauxRedis.calls(server)
    assert calls_before == []

    {:ok, port} = start_client_and_echo(server, "foo")
    assert is_integer(port)

    [call] = FauxRedis.calls(server)
    assert call.name == "ECHO"
    assert call.args == ["foo"]
  end

  test "expectations track usage", %{redis_server: server} do
    {:ok, _} = FauxRedis.expect(server, :echo, "X")

    {:ok, port} = start_client_and_echo(server, "ping")
    assert is_integer(port)

    [call] = FauxRedis.calls(server)
    assert call.rule_id != nil
  end

  test "reset!/1 clears rules and state", %{redis_server: server} do
    {:ok, _} = FauxRedis.stub(server, :echo, "x")
    :ok = FauxRedis.reset!(server)
    assert [] == FauxRedis.calls(server)
  end

  defp start_client_and_echo(server, msg) do
    port = FauxRedis.port(server)

    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", port, [:binary, packet: :raw, active: false])

    payload = FauxRedis.RESP.encode(["ECHO", msg]) |> IO.iodata_to_binary()
    :ok = :gen_tcp.send(socket, payload)
    # Read full response so Server has finished processing before we call FauxRedis.calls/1
    _ = recv_until_one_value(socket)
    :gen_tcp.close(socket)
    {:ok, port}
  end

  defp recv_until_one_value(socket, buffer \\ <<>>) do
    case FauxRedis.RESP.decode(buffer) do
      {:ok, value, _rest} ->
        value

      _ ->
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, more} -> recv_until_one_value(socket, buffer <> more)
          {:error, _} -> nil
        end
    end
  end
end
