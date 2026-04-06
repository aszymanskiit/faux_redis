defmodule FauxRedis.Connection do
  @moduledoc """
  Per-client connection process.

  Each accepted TCP socket is owned by a `FauxRedis.Connection` process,
  which is responsible for:

    * reading bytes from the socket and buffering them
    * decoding RESP frames (including pipelined commands)
    * sending commands to `FauxRedis.Server`
    * applying response specifications (including delays, timeouts, closes,
      partial/protocol-error replies)
    * handling server-side pub/sub messages
  """

  use GenServer

  require Logger
  alias FauxRedis.{Command, RESP}

  defstruct socket: nil,
            server: nil,
            conn_id: nil,
            db: 0,
            buffer: <<>>,
            closed?: false,
            mode: :mock_first,
            ets_kv: nil

  @type t :: %__MODULE__{
          socket: port() | nil,
          server: pid() | nil,
          conn_id: non_neg_integer() | nil,
          db: non_neg_integer(),
          buffer: binary(),
          closed?: boolean(),
          mode: atom(),
          ets_kv: term()
        }

  @spec start_link(pid(), port(), non_neg_integer()) :: GenServer.on_start()
  def start_link(server, socket, conn_id) when is_port(socket) do
    GenServer.start_link(__MODULE__, {server, socket, conn_id})
  end

  @spec start_link(pid(), non_neg_integer()) :: GenServer.on_start()
  def start_link(server, conn_id) do
    GenServer.start_link(__MODULE__, {server, conn_id})
  end

  @impl GenServer
  def init({server, socket, conn_id}) when is_port(socket) do
    state = %__MODULE__{socket: socket, server: server, conn_id: conn_id}
    {:ok, state}
  end

  def init({server, conn_id}) do
    state = %__MODULE__{socket: nil, server: server, conn_id: conn_id}
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:socket_ready, state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok ->
        {:noreply, state}

      {:error, _reason} ->
        # Socket is no longer valid; stop this connection process
        {:stop, :normal, state}
    end
  end

  # Backward compat: socket without mode/ets
  def handle_info({:socket, socket}, %{socket: nil} = state) do
    handle_info({:socket, socket, :mock_first, nil}, state)
  end

  def handle_info({:socket, socket, mode}, %{socket: nil} = state) do
    handle_info({:socket, socket, mode, nil}, state)
  end

  def handle_info({:socket, socket, mode, ets_kv}, %{socket: nil} = state) do
    case :inet.setopts(socket, active: :once) do
      :ok ->
        Logger.debug("[FauxRedis.Connection] conn_id=#{state.conn_id} socket assigned")
        pending = flush_tcp(socket)
        state = %{state | socket: socket, mode: mode, ets_kv: ets_kv}

        state =
          if pending == <<>> do
            state
          else
            buffer = state.buffer <> pending
            {rest, state} = process_buffer(buffer, state)
            %{state | buffer: rest}
          end

        # Ready for next TCP packet (second and later commands on this connection)
        case :inet.setopts(socket, active: :once) do
          :ok ->
            {:noreply, state}

          {:error, reason} ->
            Logger.debug(
              "[FauxRedis.Connection] conn_id=#{state.conn_id} second setopts failed: #{inspect(reason)}"
            )

            {:stop, :normal, state}
        end

      {:error, reason} ->
        Logger.debug(
          "[FauxRedis.Connection] conn_id=#{state.conn_id} setopts failed: #{inspect(reason)}"
        )

        {:stop, :normal, state}
    end
  end

  def handle_info({:socket_ready, pending}, state) when is_binary(pending) do
    case :inet.setopts(state.socket, active: :once) do
      :ok ->
        state =
          if pending == <<>> do
            state
          else
            buffer = state.buffer <> pending
            {rest, state} = process_buffer(buffer, state)
            %{state | buffer: rest}
          end

        {:noreply, state}

      {:error, reason} ->
        Logger.debug(
          "[FauxRedis.Connection] conn_id=#{state.conn_id} socket_ready setopts failed: #{inspect(reason)}"
        )

        {:stop, :normal, state}
    end
  end

  def handle_info({:tcp, _socket, data}, %{socket: nil} = state) do
    # Data arrived before we got {:socket, socket}; buffer it.
    {:noreply, %{state | buffer: state.buffer <> data}}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    buffer = state.buffer <> data
    {buffer, state} = process_buffer(buffer, state)

    case :inet.setopts(socket, active: :once) do
      :ok ->
        {:noreply, %{state | buffer: buffer}}

      {:error, reason} ->
        Logger.debug(
          "[FauxRedis.Connection] conn_id=#{state.conn_id} tcp setopts failed: #{inspect(reason)}"
        )

        {:stop, :normal, state}
    end
  end

  def handle_info({:tcp_closed, _socket}, %{socket: nil} = state) do
    # Client closed before we got {:socket, socket}; exit so pool doesn't keep a dead connection.
    {:stop, :normal, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    cleanup_and_stop(state)
  end

  def handle_info({:tcp_error, _socket, _reason}, %{socket: nil} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state) do
    cleanup_and_stop(state)
  end

  def handle_info(:connection_send_failed, state) do
    cleanup_and_stop(state)
  end

  def handle_info({:delayed_reply, response_spec}, state) do
    _ = apply_response_spec(response_spec, state)
    {:noreply, state}
  end

  def handle_info({:pubsub_message, channel, payload}, state) do
    # RESP array: ["message", channel, payload]
    payload_iodata = RESP.encode(["message", channel, payload])
    _ = :gen_tcp.send(state.socket, payload_iodata)

    {:noreply, state}
  end

  defp process_buffer(buffer, state) do
    case RESP.decode(buffer) do
      {:ok, value, rest} ->
        new_state =
          case value do
            list when is_list(list) ->
              handle_command(list, state)

            _other ->
              # For non-array inputs, respond with a protocol error.
              payload = RESP.encode({:error, "ERR Protocol error: expected array"})

              maybe_stop_on_send_error(:gen_tcp.send(state.socket, payload))

              state
          end

        process_buffer(rest, new_state)

      :more ->
        {buffer, state}

      {:error, _reason} ->
        payload = RESP.encode({:error, "ERR Protocol error"})
        maybe_stop_on_send_error(:gen_tcp.send(state.socket, payload))

        {<<>>, state}
    end
  end

  # Long timeout so a busy Server (e.g. shared Redis) does not kill this connection.
  @command_reply_timeout 60_000

  defp handle_command(list, state) do
    cmd = Command.from_array(list, state.conn_id, state.db)
    name = cmd.name

    # Handle handshake and simple commands locally so the client never blocks on the Server queue
    # (like Redis: respond immediately to HELLO/PING so connection stays alive).
    case maybe_handle_local(cmd, state) do
      {:ok, new_state} ->
        new_state

      :forward ->
        Logger.debug(
          "[FauxRedis.Connection] conn_id=#{state.conn_id} sending command #{name} to server"
        )

        ref = make_ref()
        GenServer.cast(state.server, {:command, self(), ref, state.conn_id, state.db, cmd})

        receive do
          {:command_reply, ^ref, {response_spec, new_db}} ->
            Logger.debug("[FauxRedis.Connection] conn_id=#{state.conn_id} got reply for #{name}")
            _ = apply_response_spec(response_spec, state)
            %{state | db: new_db}
        after
          @command_reply_timeout ->
            Logger.warning("[FauxRedis.Connection] conn_id=#{state.conn_id} timeout for #{name}")
            exit(:timeout)
        end
    end
  end

  @spec maybe_handle_local(Command.t(), t()) :: {:ok, t()} | :forward
  defp maybe_handle_local(%{name: "HELLO", args: ["3" | _]}, state) do
    resp = [
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

    send_resp(state, resp)
    {:ok, state}
  end

  defp maybe_handle_local(%{name: "HELLO"}, state) do
    resp = [
      "server",
      "faux-redis",
      "proto",
      2,
      "id",
      "faux-redis",
      "mode",
      Atom.to_string(state.mode)
    ]

    send_resp(state, resp)
    {:ok, state}
  end

  defp maybe_handle_local(%{name: "PING", args: []}, state) do
    send_resp(state, "PONG")
    {:ok, state}
  end

  defp maybe_handle_local(%{name: "PING", args: [msg]}, state) do
    send_resp(state, msg)
    {:ok, state}
  end

  defp maybe_handle_local(%{name: "SELECT", args: [index]}, state) do
    case Integer.parse(index) do
      {i, ""} when i >= 0 ->
        send_resp(state, :ok)
        {:ok, %{state | db: i}}

      _ ->
        send_resp(state, {:error, "ERR invalid DB index"})
        {:ok, state}
    end
  end

  defp maybe_handle_local(%{name: "MULTI"}, state) do
    # Minimal transactional support: acknowledge MULTI so that
    # transactional isolation, which is sufficient for tests.
    send_resp(state, "OK")
    {:ok, state}
  end

  defp maybe_handle_local(%{name: "EXEC"}, state) do
    # Return an empty result list for EXEC;
    send_resp(state, [])
    {:ok, state}
  end

  defp maybe_handle_local(%{name: "DISCARD"}, state) do
    send_resp(state, "OK")
    {:ok, state}
  end

  defp maybe_handle_local(_, _state), do: :forward

  defp send_resp(state, value) do
    payload = RESP.encode(value)
    maybe_stop_on_send_error(:gen_tcp.send(state.socket, payload))
  end

  defp apply_response_spec({:delay, ms, inner}, _state) do
    Process.send_after(self(), {:delayed_reply, inner}, ms)
    :ok
  end

  defp apply_response_spec(:timeout, _state), do: :ok
  defp apply_response_spec(:no_reply, _state), do: :ok

  defp apply_response_spec(:close, state) do
    :gen_tcp.close(state.socket)
    :ok
  end

  defp apply_response_spec({:close, inner}, state) do
    _ = apply_response_spec(inner, state)
    :gen_tcp.close(state.socket)
    :ok
  end

  defp apply_response_spec({:protocol_error, bytes}, state) do
    maybe_stop_on_send_error(:gen_tcp.send(state.socket, bytes))
    :ok
  end

  defp apply_response_spec({:partial, chunks}, state) when is_list(chunks) do
    Enum.each(chunks, fn chunk ->
      maybe_stop_on_send_error(:gen_tcp.send(state.socket, chunk))
    end)

    :ok
  end

  defp apply_response_spec(value, state) do
    payload = RESP.encode(value)
    maybe_stop_on_send_error(:gen_tcp.send(state.socket, payload))
    :ok
  end

  defp maybe_stop_on_send_error(:ok), do: :ok

  defp maybe_stop_on_send_error({:error, _}) do
    send(self(), :connection_send_failed)
    :ok
  end

  defp cleanup_and_stop(state) do
    GenServer.cast(state.server, {:connection_closed, state.conn_id, self()})
    {:stop, :normal, %{state | closed?: true}}
  end

  defp flush_tcp(socket) do
    flush_tcp(socket, [])
  end

  defp flush_tcp(socket, acc) do
    receive do
      {:tcp, ^socket, data} -> flush_tcp(socket, [data | acc])
    after
      0 -> acc |> Enum.reverse() |> :erlang.iolist_to_binary()
    end
  end
end
