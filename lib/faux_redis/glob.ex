defmodule FauxRedis.Glob do
  @moduledoc """
  Redis-style glob pattern matching used by `KEYS` and `SCAN ... MATCH`.

  Supports the pattern syntax documented for Redis `KEYS`:

  * `*` – matches any number of characters (including zero)
  * `?` – matches exactly one character
  * `[aeiou]` – matches a single character from the set
  * `[^aeiou]` – matches a single character not in the set
  * `[a-z]` – character ranges inside a class
  * `\\` – escapes the next pattern character so it is matched literally

  Matching is byte-oriented, consistent with Redis key comparison.
  """

  @spec match?(binary(), binary()) :: boolean()
  def match?(text, pattern) when is_binary(text) and is_binary(pattern) do
    case unescape_and_match(text, pattern) do
      :ok -> true
      :fail -> false
    end
  end

  defp unescape_and_match(<<>>, <<>>), do: :ok
  defp unescape_and_match(_text, <<>>), do: :fail

  defp unescape_and_match(text, <<?*, rest::binary>>) do
    star_match(text, rest)
  end

  defp unescape_and_match(text, <<??, rest::binary>>) do
    case text do
      <<_char, text_rest::binary>> -> unescape_and_match(text_rest, rest)
      <<>> -> :fail
    end
  end

  defp unescape_and_match(text, <<"[", _::binary>> = pattern) do
    with {:ok, class, rest} <- parse_char_class(pattern),
         <<char, text_rest::binary>> <- text,
         true <- char_in_class?(char, class) do
      unescape_and_match(text_rest, rest)
    else
      _ -> :fail
    end
  end

  defp unescape_and_match(<<char, text_rest::binary>>, <<?\\, char, rest::binary>>) do
    unescape_and_match(text_rest, rest)
  end

  defp unescape_and_match(<<char, text_rest::binary>>, <<char, rest::binary>>)
       when char != ?* and char != ?? and char != ?[ and char != ?\\ do
    unescape_and_match(text_rest, rest)
  end

  defp unescape_and_match(_text, _pattern), do: :fail

  defp star_match(text, pattern) do
    case unescape_and_match(text, pattern) do
      :ok ->
        :ok

      :fail ->
        case text do
          <<_char, text_rest::binary>> -> star_match(text_rest, pattern)
          <<>> -> :fail
        end
    end
  end

  defp parse_char_class(<<"[", rest::binary>>) do
    {negated?, rest} = parse_class_negation(rest)
    {members, rest} = parse_class_members(rest, [])

    case rest do
      <<"]", rest_after::binary>> ->
        {:ok, %{negated?: negated?, members: Enum.reverse(members)}, rest_after}

      _ ->
        :error
    end
  end

  defp parse_char_class(_), do: :error

  defp parse_class_negation(<<?^, rest::binary>>), do: {true, rest}
  defp parse_class_negation(<<?!, rest::binary>>), do: {true, rest}
  defp parse_class_negation(rest), do: {false, rest}

  defp parse_class_members(<<"]", rest::binary>>, members) do
    {members, <<"]", rest::binary>>}
  end

  defp parse_class_members(<<?\\, char, rest::binary>>, members) do
    parse_class_members(rest, [{:literal, char} | members])
  end

  defp parse_class_members(<<char, ?-, char2, rest::binary>>, members) when char2 != ?] do
    parse_class_members(rest, [{:range, char, char2} | members])
  end

  defp parse_class_members(<<char, rest::binary>>, members) do
    parse_class_members(rest, [{:literal, char} | members])
  end

  defp parse_class_members(<<>>, members), do: {members, <<>>}

  defp char_in_class?(char, %{negated?: negated?, members: members}) do
    member? = Enum.any?(members, &class_member_matches?(char, &1))
    if negated?, do: not member?, else: member?
  end

  defp class_member_matches?(char, {:literal, char}), do: true
  defp class_member_matches?(char, {:range, from, to}), do: char >= from and char <= to
  defp class_member_matches?(_char, _), do: false
end
