defmodule FauxRedis.ScriptTest do
  use ExUnit.Case, async: true

  alias FauxRedis.Script

  # Echoes the command back as a list and records it in the state.
  defp echo_call(argv, calls), do: {argv, [argv | calls]}

  defp eval(script, keys \\ [], args \\ [], call_fun \\ &echo_call/2) do
    Script.eval(script, keys, args, [], call_fun)
  end

  test "exposes KEYS and ARGV" do
    assert {["k1", "k2", "a1"], []} =
             eval("return {KEYS[1], KEYS[2], ARGV[1]}", ["k1", "k2"], ["a1"])
  end

  test "redis.call passes stringified arguments and threads state" do
    assert {["SET", "k", "5", "2.5"], [["SET", "k", "5", "2.5"]]} =
             eval("return redis.call('SET', 'k', 5, 2.5)")
  end

  test "converts Lua return values to Redis replies" do
    assert {3, _} = eval("return 3.9")
    assert {nil, _} = eval("return false")
    assert {nil, _} = eval("return nil")
    assert {1, _} = eval("return true")
    assert {nil, _} = eval("local x = 1")
    assert {["a", 1, ["b"]], _} = eval("return {'a', 1, {'b'}, nil, 'ignored'}")
    assert {{:simple_string, "FINE"}, _} = eval("return redis.status_reply('FINE')")
    assert {{:error, "ERR custom"}, _} = eval("return redis.error_reply('ERR custom')")
  end

  test "converts Redis replies to Lua values" do
    replies = fn
      ["NIL"], st -> {nil, st}
      ["OK"], st -> {:ok, st}
      ["INT"], st -> {42, st}
      ["ERR"], st -> {{:error, "ERR nope"}, st}
    end

    assert {1, _} = eval("return redis.call('NIL') == false and 1 or 0", [], [], replies)
    assert {"OK", _} = eval("return redis.call('OK').ok", [], [], replies)
    assert {43, _} = eval("return redis.call('INT') + 1", [], [], replies)
    assert {{:error, "ERR nope"}, _} = eval("return redis.call('ERR')", [], [], replies)
    assert {"ERR nope", _} = eval("return redis.pcall('ERR').err", [], [], replies)
  end

  test "reports runtime and compile errors" do
    assert {{:error, "ERR user_script: boom"}, _} = eval("error('boom')")
    assert {{:error, "ERR Error running script: " <> _}, _} = eval("local x = nil; return x.y")
    assert {{:error, "ERR Error compiling script: " <> _}, []} = eval("x = = 1")
  end

  test "keeps writes made before a runtime error" do
    assert {{:error, _}, [["SET", "a", "1"]]} = eval("redis.call('SET', 'a', '1'); error('x')")
  end

  test "treats scripts and arguments as UTF-8 byte strings" do
    assert {["zażółć", "łódź", 2], _} = eval("return {'zażółć', ARGV[1], #'ż'}", [], ["łódź"])
  end

  test "sha1 matches Redis script digests" do
    assert Script.sha1("return 1") == "e0e1f9fabfc9d4800c877a703b823ac0578ff8db"
  end
end
