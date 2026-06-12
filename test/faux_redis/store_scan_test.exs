defmodule FauxRedis.StoreScanTest do
  use ExUnit.Case, async: true

  alias FauxRedis.Store

  defp store_with_keys(keys) do
    Enum.reduce(keys, Store.new(), fn key, store ->
      Store.set(store, key, "value")
    end)
  end

  test "scan without pattern returns all keys sorted" do
    store = store_with_keys(["b", "a", "c"])

    {^store, {"0", keys}} = Store.scan(store, "*", 10)

    assert keys == ["a", "b", "c"]
  end

  test "scan with *@* returns only keys containing @" do
    store =
      store_with_keys([
        "user1@example.com",
        "user2@example.com",
        "plain",
        "also-no-at"
      ])

    {^store, {"0", keys}} = Store.scan(store, "*@*", 100)

    assert Enum.sort(keys) == ["user1@example.com", "user2@example.com"]
  end

  test "scan respects COUNT limit" do
    store = store_with_keys(["a", "b", "c", "d"])

    {^store, {"0", keys}} = Store.scan(store, "*", 2)

    assert length(keys) == 2
    assert keys == Enum.sort(["a", "b", "c", "d"]) |> Enum.take(2)
  end

  test "scan with COUNT <= 0 returns empty batch" do
    store = store_with_keys(["a"])

    {^store, {"0", []}} = Store.scan(store, "*", 0)
    {^store, {"0", []}} = Store.scan(store, "*", -1)
  end
end
