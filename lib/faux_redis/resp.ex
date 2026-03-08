defmodule FauxRedis.RESP do
  @moduledoc """
  Minimal RESP2 encoder/decoder used by `FauxRedis`.

  This module is intentionally self-contained and does not depend on the rest
  of the application. It operates purely on binaries and iodata.

  Supported types:

    * simple strings – `{:simple_string, binary}` or the atom `:ok`
    * errors – `{:error, binary}` or `{:error, :noauth}` etc.
    * integers – `{:integer, integer}` or plain integers
    * bulk strings – `{:bulk, binary | nil}` or plain binaries / `nil`
    * arrays – `{:array, list}` or plain lists

  The parser understands all of these forms and returns Elixir values:

    * simple string → binary
    * error → `{:error, binary}`
    * integer → integer
    * bulk → binary | nil
    * array → list
  """

  @type decoded ::
          binary()
          | {:error, binary()}
          | integer()
          | nil
          | [decoded()]

  @doc """
  Decodes a single RESP value from the given binary.

  Returns:

    * `{:ok, value, rest}` – successfully decoded one value
    * `:more` – more data is required
    * `{:error, reason}` – malformed input
  """
  @spec decode(binary()) :: {:ok, decoded(), binary()} | :more | {:error, term()}
  def decode(<<>>) do
    :more
  end

  def decode(<<"*", rest::binary>>) do
    with {:ok, count, after_len} <- parse_integer_line(rest),
         {:ok, items, rest2} <- decode_array_items(count, after_len, []) do
      {:ok, items, rest2}
    else
      :more -> :more
      {:error, _} = err -> err
    end
  end

  def decode(<<"+", rest::binary>>) do
    case read_line(rest) do
      {:ok, line, rest2} -> {:ok, line, rest2}
      :more -> :more
    end
  end

  def decode(<<"-", rest::binary>>) do
    case read_line(rest) do
      {:ok, line, rest2} -> {:ok, {:error, line}, rest2}
      :more -> :more
    end
  end

  def decode(<<":", rest::binary>>) do
    case parse_integer_line(rest) do
      {:ok, int, rest2} -> {:ok, int, rest2}
      :more -> :more
      {:error, _} = err -> err
    end
  end

  def decode(<<"$", rest::binary>>) do
    with {:ok, len, after_len} <- parse_integer_line(rest),
         {:ok, value, rest2} <- read_bulk(len, after_len) do
      {:ok, value, rest2}
    else
      :more -> :more
      {:error, _} = err -> err
    end
  end

  def decode(_other) do
    {:error, :invalid_prefix}
  end

  @doc """
  Encodes a value into RESP iodata.

  Accepted forms:

    * binary – bulk string
    * nil – null bulk string
    * integer – integer reply
    * list – array
    * `{:error, message}` – error reply
    * `{:simple_string, message}` – simple string
    * `:ok` – simple string \"OK\"
  """
  @spec encode(term()) :: iodata()
  def encode(:ok), do: encode({:simple_string, "OK"})

  def encode({:simple_string, msg}) when is_binary(msg) do
    ["+", msg, "\r\n"]
  end

  def encode({:error, msg}) when is_binary(msg) do
    ["-", msg, "\r\n"]
  end

  def encode(int) when is_integer(int) do
    [":", Integer.to_string(int), "\r\n"]
  end

  def encode(nil) do
    ["$", "-1", "\r\n"]
  end

  def encode(bin) when is_binary(bin) do
    ["$", byte_size(bin) |> Integer.to_string(), "\r\n", bin, "\r\n"]
  end

  def encode(list) when is_list(list) do
    ["*", Integer.to_string(length(list)), "\r\n", Enum.map(list, &encode/1)]
  end

  def encode(other) do
    encode(to_string(other))
  end

  @doc """
  Convenience function for decoding exactly one value and asserting that the
  buffer has been fully consumed.
  """
  @spec decode_exactly(binary()) :: {:ok, decoded()} | :more | {:error, term()}
  def decode_exactly(binary) do
    case decode(binary) do
      {:ok, value, <<>>} -> {:ok, value}
      {:ok, _value, _rest} -> {:error, :trailing_bytes}
      other -> other
    end
  end

  # Internal helpers

  @spec read_line(binary()) :: {:ok, binary(), binary()} | :more
  defp read_line(binary) do
    case :binary.match(binary, "\r\n") do
      {idx, 2} ->
        <<line::binary-size(idx), _crlf::binary-size(2), rest::binary>> = binary
        {:ok, line, rest}

      :nomatch ->
        :more
    end
  end

  @spec parse_integer_line(binary()) :: {:ok, integer(), binary()} | :more | {:error, term()}
  defp parse_integer_line(binary) do
    with {:ok, line, rest} <- read_line(binary) do
      case Integer.parse(line) do
        {int, ""} -> {:ok, int, rest}
        _ -> {:error, :invalid_integer}
      end
    end
  end

  @spec read_bulk(integer(), binary()) ::
          {:ok, binary() | nil, binary()} | :more | {:error, term()}
  defp read_bulk(-1, rest), do: {:ok, nil, rest}

  defp read_bulk(len, binary) when len >= 0 do
    need = len + 2

    if byte_size(binary) < need do
      :more
    else
      <<data::binary-size(len), "\r\n", rest::binary>> = binary
      {:ok, data, rest}
    end
  end

  defp read_bulk(_, _), do: {:error, :invalid_bulk_length}

  @spec decode_array_items(integer(), binary(), [decoded()]) ::
          {:ok, [decoded()], binary()} | :more | {:error, term()}
  defp decode_array_items(0, rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_array_items(n, binary, acc) when n > 0 do
    case decode(binary) do
      {:ok, value, rest} ->
        decode_array_items(n - 1, rest, [value | acc])

      :more ->
        :more

      {:error, _} = err ->
        err
    end
  end

  defp decode_array_items(_, _binary, _acc), do: {:error, :invalid_array_length}
end
