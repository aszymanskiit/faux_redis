defmodule FauxRedis.Script do
  @moduledoc """
  Executes Lua scripts for `EVAL` / `EVALSHA` on the pure-Erlang `luerl` VM.

  Scripts see the usual `KEYS` / `ARGV` tables and a `redis` table with
  `call`, `pcall`, `status_reply`, `error_reply`, `sha1hex` and a no-op `log`.
  Every `redis.call` is passed to the `call_fun` supplied by the server, so
  scripts operate on the same in-memory store as regular commands.

  Values are converted between Redis replies and Lua following the rules of
  real Redis (nil bulk → `false`, status → `{ok = ...}`, Lua numbers →
  integers truncated towards zero, and so on).
  """

  @typedoc "Callback executing one Redis command on behalf of the script."
  @type call_fun :: ([binary()], term() -> {term(), term()})

  @prelude """
  redis = {}
  redis.LOG_DEBUG, redis.LOG_VERBOSE, redis.LOG_NOTICE, redis.LOG_WARNING = 0, 1, 2, 3

  function redis.pcall(...)
    return __faux_redis_call(...)
  end

  function redis.call(...)
    local reply = __faux_redis_call(...)
    if type(reply) == 'table' and reply.err then
      error(reply)
    end
    return reply
  end

  function redis.status_reply(msg) return {ok = msg} end
  function redis.error_reply(msg) return {err = msg} end
  function redis.log(level, ...) end
  function redis.sha1hex(s) return __faux_redis_sha1hex(s) end
  """

  @doc "Returns the lowercase hex SHA1 digest Redis uses to identify a script."
  @spec sha1(binary()) :: binary()
  def sha1(script), do: :crypto.hash(:sha, script) |> Base.encode16(case: :lower)

  @doc """
  Runs `script` with the given `keys` and `args`.

  `state` is threaded through every `call_fun` invocation; the final state is
  returned alongside the script's reply (converted to a Redis reply term).
  As in Redis, writes made before a runtime error are kept.
  """
  @spec eval(binary(), [binary()], [binary()], state, call_fun()) :: {term(), state}
        when state: term()
  def eval(script, keys, args, state, call_fun) do
    lua = setup(keys, args, state, call_fun)

    case :luerl.do(:binary.bin_to_list(script), lua) do
      {:ok, [ret | _], lua} -> {to_redis(:luerl.decode(ret, lua)), server_state(lua)}
      {:ok, [], lua} -> {nil, server_state(lua)}
      {:lua_error, error, lua} -> {{:error, runtime_error(error, lua)}, server_state(lua)}
      {:error, errors, _warnings} -> {{:error, compile_error(errors)}, state}
    end
  rescue
    e -> {{:error, "ERR Error running script: #{Exception.message(e)}"}, state}
  end

  defp setup(keys, args, state, call_fun) do
    lua = :luerl.put_private(:server_state, state, :luerl.init())
    {call, lua} = :luerl.encode(&redis_call(&1, &2, call_fun), lua)
    {sha1hex, lua} = :luerl.encode(&sha1hex/2, lua)
    {:ok, lua} = :luerl.set_table_keys(["__faux_redis_call"], call, lua)
    {:ok, lua} = :luerl.set_table_keys(["__faux_redis_sha1hex"], sha1hex, lua)
    {:ok, lua} = :luerl.set_table_keys_dec(["KEYS"], keys, lua)
    {:ok, lua} = :luerl.set_table_keys_dec(["ARGV"], args, lua)
    {:ok, _, lua} = :luerl.do(:binary.bin_to_list(@prelude), lua)
    lua
  end

  defp server_state(lua), do: :luerl.get_private(:server_state, lua)

  defp redis_call(lua_args, lua, call_fun) do
    case lua_args |> :luerl.decode_list(lua) |> to_command_args() do
      {:ok, []} ->
        encode_reply(
          {:error, "ERR Please specify at least one argument for this redis lib call"},
          lua
        )

      {:ok, argv} ->
        {reply, state} = call_fun.(argv, server_state(lua))
        encode_reply(reply, :luerl.put_private(:server_state, state, lua))

      :error ->
        encode_reply(
          {:error, "ERR Lua redis lib command arguments must be strings or integers"},
          lua
        )
    end
  end

  defp encode_reply(reply, lua) do
    {value, lua} = :luerl.encode(to_lua(reply), lua)
    {[value], lua}
  end

  defp sha1hex([script | _], lua) when is_binary(script), do: {[sha1(script)], lua}
  defp sha1hex(_args, lua), do: {[sha1("")], lua}

  defp to_command_args(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case to_command_arg(value) do
        nil -> {:halt, :error}
        arg -> {:cont, {:ok, [arg | acc]}}
      end
    end)
    |> case do
      {:ok, args} -> {:ok, Enum.reverse(args)}
      :error -> :error
    end
  end

  defp to_command_arg(value) when is_binary(value), do: value
  defp to_command_arg(value) when is_integer(value), do: Integer.to_string(value)
  defp to_command_arg(value) when is_float(value) and value == trunc(value), do: "#{trunc(value)}"
  defp to_command_arg(value) when is_float(value), do: Float.to_string(value)
  defp to_command_arg(_value), do: nil

  # Redis reply -> Lua value (encodable by luerl)
  defp to_lua(nil), do: false
  defp to_lua(:ok), do: [{"ok", "OK"}]
  defp to_lua({:simple_string, msg}), do: [{"ok", msg}]
  defp to_lua({:error, msg}), do: [{"err", msg}]
  defp to_lua(value) when is_integer(value) or is_binary(value), do: value
  defp to_lua(list) when is_list(list), do: Enum.map(list, &to_lua/1)
  defp to_lua(_other), do: false

  # Decoded Lua value -> Redis reply
  defp to_redis(value) when value in [nil, false], do: nil
  defp to_redis(true), do: 1
  defp to_redis(value) when is_integer(value) or is_binary(value), do: value
  defp to_redis(value) when is_float(value), do: trunc(value)

  defp to_redis(table) when is_list(table) do
    fields = Map.new(table)

    cond do
      is_binary(fields["err"]) -> {:error, fields["err"]}
      is_binary(fields["ok"]) -> {:simple_string, fields["ok"]}
      true -> table_array(fields, 1, [])
    end
  end

  defp to_redis(_other), do: nil

  # Lua arrays end at the first nil, exactly like Redis' conversion.
  defp table_array(fields, index, acc) do
    case Map.fetch(fields, index) do
      {:ok, value} -> table_array(fields, index + 1, [to_redis(value) | acc])
      :error -> Enum.reverse(acc)
    end
  end

  defp runtime_error({:error_call, [message | _]}, lua) do
    case to_redis(:luerl.decode(message, lua)) do
      {:error, msg} -> msg
      msg when is_binary(msg) -> "ERR user_script: #{msg}"
      other -> "ERR user_script: #{inspect(other)}"
    end
  end

  defp runtime_error(error, _lua) do
    "ERR Error running script: #{format_luerl_error(error)}"
  end

  defp format_luerl_error(error) do
    error |> :luerl_lib.format_error() |> IO.chardata_to_string()
  rescue
    _ -> inspect(error)
  end

  defp compile_error([{line, module, description} | _]) do
    "ERR Error compiling script: line #{line}: #{module.format_error(description)}"
  rescue
    _ -> "ERR Error compiling script"
  end

  defp compile_error(_errors), do: "ERR Error compiling script"
end
