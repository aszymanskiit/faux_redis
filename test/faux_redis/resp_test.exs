defmodule FauxRedis.RESPTest do
  use ExUnit.Case, async: true

  alias FauxRedis.RESP

  describe "encode/decode roundtrips" do
    test "simple strings" do
      assert "+OK\r\n" == IO.iodata_to_binary(RESP.encode({:simple_string, "OK"}))
      assert {:ok, "OK"} == RESP.decode_exactly("+OK\r\n")
    end

    test "errors" do
      encoded = IO.iodata_to_binary(RESP.encode({:error, "ERR fail"}))
      assert encoded == "-ERR fail\r\n"
      assert {:ok, {:error, "ERR fail"}} == RESP.decode_exactly(encoded)
    end

    test "integers" do
      encoded = IO.iodata_to_binary(RESP.encode(42))
      assert encoded == ":42\r\n"
      assert {:ok, 42} == RESP.decode_exactly(encoded)
    end

    test "bulk strings and nil" do
      encoded = IO.iodata_to_binary(RESP.encode("foo"))
      assert encoded == "$3\r\nfoo\r\n"
      assert {:ok, "foo"} == RESP.decode_exactly(encoded)

      assert "$-1\r\n" == IO.iodata_to_binary(RESP.encode(nil))
      assert {:ok, nil} == RESP.decode_exactly("$-1\r\n")
    end

    test "arrays" do
      value = ["PING", "hello"]
      encoded = IO.iodata_to_binary(RESP.encode(value))
      assert {:ok, decoded} = RESP.decode_exactly(encoded)
      assert decoded == value
    end
  end

  describe "streaming decode" do
    test "decodes multiple pipelined commands" do
      payload =
        IO.iodata_to_binary([
          RESP.encode(["PING"]),
          RESP.encode(["ECHO", "hi"])
        ])

      assert {:ok, ["PING"], rest} = RESP.decode(payload)
      assert {:ok, ["ECHO", "hi"], ""} = RESP.decode(rest)
    end

    test "returns :more when data is incomplete" do
      assert :more == RESP.decode("*2\r\n$4\r\nPING\r\n$")
    end
  end
end
