defmodule FauxRedis.StoreZsetTest do
  use ExUnit.Case, async: true

  alias FauxRedis.Store

  @wrongtype "WRONGTYPE Operation against a key holding the wrong kind of value"

  defp zset(pairs) do
    {store, _} = Store.zadd(Store.new(), "z", pairs)
    store
  end

  test "zadd returns number of new members and updates existing scores" do
    {store, 2} = Store.zadd(Store.new(), "z", [{1.0, "a"}, {2.0, "b"}])
    {store, 1} = Store.zadd(store, "z", [{5.0, "a"}, {3.0, "c"}])
    {_store, 5.0} = Store.zscore(store, "z", "a")
  end

  test "zadd NX only adds new members" do
    {store, 1} = Store.zadd(zset([{1.0, "a"}]), "z", [{9.0, "a"}, {2.0, "b"}], %{nx: true})
    {_store, 1.0} = Store.zscore(store, "z", "a")
  end

  test "zadd XX only updates existing members and does not create the key" do
    {store, 0} = Store.zadd(Store.new(), "z", [{1.0, "a"}], %{xx: true})
    {_store, 0} = Store.exists(store, ["z"])

    {store, 0} = Store.zadd(zset([{1.0, "a"}]), "z", [{9.0, "a"}, {2.0, "b"}], %{xx: true})
    {store, 9.0} = Store.zscore(store, "z", "a")
    {_store, nil} = Store.zscore(store, "z", "b")
  end

  test "zadd GT/LT only move scores in one direction and CH counts changes" do
    store = zset([{5.0, "a"}, {5.0, "b"}])
    {store, 1} = Store.zadd(store, "z", [{6.0, "a"}, {4.0, "b"}], %{gt: true, ch: true})
    {store, 6.0} = Store.zscore(store, "z", "a")
    {store, 5.0} = Store.zscore(store, "z", "b")

    {store, 1} = Store.zadd(store, "z", [{7.0, "a"}, {4.0, "b"}], %{lt: true, ch: true})
    {_store, 4.0} = Store.zscore(store, "z", "b")
  end

  test "zrange orders by score then member, with negative and out-of-range indices" do
    store = zset([{2.0, "c"}, {1.0, "z"}, {2.0, "a"}])

    {_, [{"z", 1.0}, {"a", 2.0}, {"c", 2.0}]} = Store.zrange(store, "z", 0, -1)
    {_, [{"a", 2.0}, {"c", 2.0}]} = Store.zrange(store, "z", -2, 100)
    {_, []} = Store.zrange(store, "z", 2, 1)
    {_, []} = Store.zrange(store, "z", 5, 10)
    {_, [{"c", 2.0}, {"a", 2.0}]} = Store.zrange(store, "z", 0, 1, true)
    {_, []} = Store.zrange(store, "missing", 0, -1)
  end

  test "zrem removes members and deletes the key when empty" do
    {store, 1} = Store.zrem(zset([{1.0, "a"}, {2.0, "b"}]), "z", ["a", "nope"])
    {store, [{"b", 2.0}]} = Store.zrange(store, "z", 0, -1)
    {store, 1} = Store.zrem(store, "z", ["b"])
    {store, 0} = Store.exists(store, ["z"])
    {_store, 0} = Store.zrem(store, "z", ["b"])
  end

  test "sorted set functions return WRONGTYPE for other types" do
    store = Store.set(Store.new(), "s", "v")

    {_, {:error, @wrongtype}} = Store.zadd(store, "s", [{1.0, "a"}])
    {_, {:error, @wrongtype}} = Store.zrange(store, "s", 0, -1)
    {_, {:error, @wrongtype}} = Store.zscore(store, "s", "a")
    {_, {:error, @wrongtype}} = Store.zrem(store, "s", ["a"])
  end

  test "get and mget return nil for a zset key" do
    store = zset([{1.0, "a"}])
    {_, nil} = Store.get(store, "z")
    {_, [nil]} = Store.mget(store, ["z"])
  end
end
