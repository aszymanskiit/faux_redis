defmodule FauxRedis.Store do
  @moduledoc """
  In-memory, process-local data store that approximates a subset of Redis
  semantics sufficient for most integration tests.

  This module is not intended to be a full, production-ready Redis
  implementation – correctness and testability are prioritised over complete
  feature parity.
  """

  @typedoc "Internal representation of the store."
  @type t :: %__MODULE__{
          kv: %{binary() => value()},
          ttl: %{binary() => integer()},
          now_fn: (-> integer())
        }

  @type value ::
          binary()
          | integer()
          | {:hash, %{binary() => binary()}}
          | {:set, MapSet.t(binary())}
          | {:list, [binary()]}

  @spec system_now() :: integer()
  def system_now, do: System.system_time(:second)

  defstruct kv: %{}, ttl: %{}, now_fn: &__MODULE__.system_now/0

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec get(t(), binary()) :: {t(), nil | binary()}
  def get(store, key) do
    store = purge_expired(store)

    case Map.get(store.kv, key) do
      nil -> {store, nil}
      {:hash, _} -> {store, nil}
      {:set, _} -> {store, nil}
      {:list, _} -> {store, nil}
      value when is_binary(value) -> {store, value}
      value when is_integer(value) -> {store, Integer.to_string(value)}
    end
  end

  @spec set(t(), binary(), binary()) :: t()
  def set(store, key, value) do
    %{store | kv: Map.put(store.kv, key, value), ttl: Map.delete(store.ttl, key)}
  end

  @spec del(t(), [binary()]) :: {t(), non_neg_integer()}
  def del(store, keys) do
    {kv, ttl, deleted} =
      Enum.reduce(keys, {store.kv, store.ttl, 0}, fn key, {kv, ttl, acc} ->
        if Map.has_key?(kv, key) do
          {Map.delete(kv, key), Map.delete(ttl, key), acc + 1}
        else
          {kv, ttl, acc}
        end
      end)

    {%{store | kv: kv, ttl: ttl}, deleted}
  end

  @spec exists(t(), [binary()]) :: {t(), non_neg_integer()}
  def exists(store, keys) do
    store = purge_expired(store)

    count =
      keys
      |> Enum.count(&Map.has_key?(store.kv, &1))

    {store, count}
  end

  @spec expire(t(), binary(), integer()) :: {t(), 0 | 1}
  def expire(store, key, seconds) when seconds > 0 do
    store = purge_expired(store)

    if Map.has_key?(store.kv, key) do
      now = store.now_fn.()
      ttl = Map.put(store.ttl, key, now + seconds)
      {%{store | ttl: ttl}, 1}
    else
      {store, 0}
    end
  end

  def expire(store, _key, _seconds), do: {store, 0}

  @spec ttl(t(), binary()) :: {t(), integer()}
  def ttl(store, key) do
    store = purge_expired(store)
    now = store.now_fn.()

    case {Map.get(store.kv, key), Map.get(store.ttl, key)} do
      {nil, _} -> {store, -2}
      {_value, nil} -> {store, -1}
      {_value, expires_at} -> {store, max(expires_at - now, -2)}
    end
  end

  @spec hget(t(), binary(), binary()) :: {t(), nil | binary()}
  def hget(store, key, field) do
    store = purge_expired(store)

    case Map.get(store.kv, key) do
      {:hash, map} -> {store, Map.get(map, field)}
      _ -> {store, nil}
    end
  end

  @spec hset(t(), binary(), binary(), binary()) :: {t(), 0 | 1}
  def hset(store, key, field, value) do
    {hash, existed?} =
      case Map.get(store.kv, key) do
        nil -> {%{}, false}
        {:hash, map} -> {map, Map.has_key?(map, field)}
        _other -> {%{}, false}
      end

    new_hash = Map.put(hash, field, value)
    kv = Map.put(store.kv, key, {:hash, new_hash})
    {%{store | kv: kv}, if(existed?, do: 0, else: 1)}
  end

  @spec hgetall(t(), binary()) :: {t(), [binary()]}
  def hgetall(store, key) do
    store = purge_expired(store)

    case Map.get(store.kv, key) do
      {:hash, map} ->
        flat =
          map
          |> Enum.flat_map(fn {k, v} -> [k, v] end)

        {store, flat}

      _ ->
        {store, []}
    end
  end

  @spec sadd(t(), binary(), [binary()]) :: {t(), non_neg_integer()}
  def sadd(store, key, members) do
    {set, initial_size} =
      case Map.get(store.kv, key) do
        {:set, s} -> {s, MapSet.size(s)}
        nil -> {MapSet.new(), 0}
        _other -> {MapSet.new(), 0}
      end

    new_set = Enum.reduce(members, set, &MapSet.put(&2, &1))
    kv = Map.put(store.kv, key, {:set, new_set})
    {%{store | kv: kv}, MapSet.size(new_set) - initial_size}
  end

  @spec smembers(t(), binary()) :: {t(), [binary()]}
  def smembers(store, key) do
    store = purge_expired(store)

    case Map.get(store.kv, key) do
      {:set, set} -> {store, Enum.to_list(set)}
      _ -> {store, []}
    end
  end

  @spec srem(t(), binary(), [binary()]) :: {t(), non_neg_integer()}
  def srem(store, key, members) do
    store = purge_expired(store)

    case Map.get(store.kv, key) do
      {:set, set} ->
        {new_set, removed} = Enum.reduce(members, {set, 0}, &srem_step/2)
        {kv, ttl} = srem_update_kv_ttl(store, key, new_set)
        {%{store | kv: kv, ttl: ttl}, removed}

      _ ->
        {store, 0}
    end
  end

  defp srem_step(member, {acc_set, acc_removed}) do
    if MapSet.member?(acc_set, member) do
      {MapSet.delete(acc_set, member), acc_removed + 1}
    else
      {acc_set, acc_removed}
    end
  end

  defp srem_update_kv_ttl(store, key, new_set) do
    if MapSet.size(new_set) == 0 do
      {Map.delete(store.kv, key), Map.delete(store.ttl, key)}
    else
      {Map.put(store.kv, key, {:set, new_set}), store.ttl}
    end
  end

  @spec sismember(t(), binary(), binary()) :: {t(), 0 | 1}
  def sismember(store, key, member) do
    store = purge_expired(store)

    case Map.get(store.kv, key) do
      {:set, set} ->
        {store, if(MapSet.member?(set, member), do: 1, else: 0)}

      _ ->
        {store, 0}
    end
  end

  @spec scan(t(), binary(), non_neg_integer()) :: {t(), {binary(), [binary()]}}
  def scan(store, _pattern, count) when count <= 0 do
    {store, {"0", []}}
  end

  def scan(store, pattern, count) do
    store = purge_expired(store)

    keys =
      store.kv
      |> Map.keys()
      |> Enum.filter(&match_pattern?(&1, pattern))
      |> Enum.sort()

    {batch, _rest} = Enum.split(keys, count)

    # Always return cursor "0" – one-shot SCAN is enough for tests using FauxRedis.
    {store, {"0", batch}}
  end

  @spec sscan(t(), binary(), binary(), non_neg_integer()) :: {t(), {binary(), [binary()]}}
  def sscan(store, key, _cursor, _count) do
    store = purge_expired(store)

    members =
      case Map.get(store.kv, key) do
        {:set, set} -> Enum.to_list(set)
        _ -> []
      end

    # TemporarySubscriptionsRedis uses SSCAN in a loop until cursor == "0".
    # Returning all members in a single page with cursor "0" is sufficient.
    {store, {"0", members}}
  end

  @spec lpush(t(), binary(), [binary()]) :: {t(), non_neg_integer()}
  def lpush(store, key, values) do
    do_push(store, key, values, :left)
  end

  @spec rpush(t(), binary(), [binary()]) :: {t(), non_neg_integer()}
  def rpush(store, key, values) do
    do_push(store, key, values, :right)
  end

  defp do_push(store, key, values, side) do
    list =
      case Map.get(store.kv, key) do
        {:list, l} -> l
        nil -> []
        _other -> []
      end

    new_list =
      case side do
        :left -> Enum.reverse(values) ++ list
        :right -> list ++ values
      end

    kv = Map.put(store.kv, key, {:list, new_list})
    {%{store | kv: kv}, length(new_list)}
  end

  @spec lpop(t(), binary()) :: {t(), nil | binary()}
  def lpop(store, key) do
    case Map.get(store.kv, key) do
      {:list, [head | tail]} ->
        kv =
          if tail == [] do
            Map.delete(store.kv, key)
          else
            Map.put(store.kv, key, {:list, tail})
          end

        {%{store | kv: kv}, head}

      _ ->
        {store, nil}
    end
  end

  @spec rpop(t(), binary()) :: {t(), nil | binary()}
  def rpop(store, key) do
    case Map.get(store.kv, key) do
      {:list, list} when list != [] ->
        {init, [last]} = Enum.split(list, length(list) - 1)

        kv =
          if init == [] do
            Map.delete(store.kv, key)
          else
            Map.put(store.kv, key, {:list, init})
          end

        {%{store | kv: kv}, last}

      _ ->
        {store, nil}
    end
  end

  @spec mget(t(), [binary()]) :: {t(), [nil | binary()]}
  def mget(store, keys) do
    store = purge_expired(store)

    {store,
     Enum.map(keys, fn key ->
       case Map.get(store.kv, key) do
         nil -> nil
         {:hash, _} -> nil
         {:set, _} -> nil
         {:list, _} -> nil
         value when is_binary(value) -> value
         value when is_integer(value) -> Integer.to_string(value)
       end
     end)}
  end

  @spec mset(t(), [{binary(), binary()}]) :: t()
  def mset(store, pairs) do
    kv =
      Enum.reduce(pairs, store.kv, fn {k, v}, acc ->
        Map.put(acc, k, v)
      end)

    %{store | kv: kv}
  end

  @spec incr(t(), binary()) :: {t(), integer()}
  def incr(store, key), do: do_incr(store, key, 1)

  @spec decr(t(), binary()) :: {t(), integer()}
  def decr(store, key), do: do_incr(store, key, -1)

  defp do_incr(store, key, delta) do
    {current_int, kv} =
      case Map.get(store.kv, key) do
        nil ->
          {0, store.kv}

        value when is_integer(value) ->
          {value, store.kv}

        value when is_binary(value) ->
          case Integer.parse(value) do
            {i, ""} -> {i, store.kv}
            _ -> {0, store.kv}
          end

        _other ->
          {0, store.kv}
      end

    new_val = current_int + delta
    kv = Map.put(kv, key, new_val)
    {%{store | kv: kv}, new_val}
  end

  @spec reset(t()) :: t()
  def reset(_store), do: %__MODULE__{}

  # Simple pattern matcher for SCAN-style glob patterns limited to what
  # TemporarySubscriptions/ejabberd modules actually use (e.g. "*@*").
  defp match_pattern?(_key, "*"), do: true

  defp match_pattern?(key, pattern) when is_binary(key) and is_binary(pattern) do
    case String.split(pattern, "*") do
      ["", ""] -> String.contains?(key, "")
      [prefix, ""] -> String.starts_with?(key, prefix)
      ["", suffix] -> String.ends_with?(key, suffix)
      [prefix, suffix] -> String.starts_with?(key, prefix) and String.ends_with?(key, suffix)
      _ -> key == pattern
    end
  end

  # Expiration handling

  @spec purge_expired(t()) :: t()
  defp purge_expired(%__MODULE__{ttl: ttl, kv: kv, now_fn: now_fn} = store) do
    now = now_fn.()

    {kv, ttl} =
      Enum.reduce(ttl, {kv, ttl}, fn {key, expires_at}, {kv_acc, ttl_acc} ->
        if expires_at <= now do
          {Map.delete(kv_acc, key), Map.delete(ttl_acc, key)}
        else
          {kv_acc, ttl_acc}
        end
      end)

    %{store | kv: kv, ttl: ttl}
  end
end
