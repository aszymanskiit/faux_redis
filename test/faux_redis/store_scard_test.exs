defmodule FauxRedis.StoreScardTest do
  use ExUnit.Case, async: true

  alias FauxRedis.Store

  @wrongtype "WRONGTYPE Operation against a key holding the wrong kind of value"

  test "scard returns member count for a set" do
    store =
      Store.new()
      |> then(fn s ->
        {s, _} = Store.sadd(s, "myset", ["a", "b", "c"])
        s
      end)

    {^store, 3} = Store.scard(store, "myset")
  end

  test "scard returns 0 for a missing key" do
    store = Store.new()
    {^store, 0} = Store.scard(store, "missing")
  end

  test "scard returns 0 after all members are removed" do
    store =
      Store.new()
      |> then(fn s ->
        {s, _} = Store.sadd(s, "myset", ["only"])
        {s, _} = Store.srem(s, "myset", ["only"])
        s
      end)

    {^store, 0} = Store.scard(store, "myset")
  end

  test "scard returns WRONGTYPE for a non-set key" do
    store = Store.set(Store.new(), "str", "value")

    {^store, {:error, @wrongtype}} = Store.scard(store, "str")
  end

  test "scard returns WRONGTYPE for a hash key" do
    store =
      Store.new()
      |> then(fn s ->
        {s, _} = Store.hset(s, "hash", "field", "value")
        s
      end)

    {^store, {:error, @wrongtype}} = Store.scard(store, "hash")
  end

  test "scard returns WRONGTYPE for a list key" do
    store =
      Store.new()
      |> then(fn s ->
        {s, _} = Store.lpush(s, "list", ["a"])
        s
      end)

    {^store, {:error, @wrongtype}} = Store.scard(store, "list")
  end
end
