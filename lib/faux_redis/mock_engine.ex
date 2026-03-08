defmodule FauxRedis.MockEngine do
  @moduledoc """
  Evaluation engine for mock and expectation rules.

  It is responsible for:

    * matching incoming commands against configured rules
    * supporting sequence responses (lists) and callback functions
    * tracking usage counts for expectations
    * returning a concrete response specification for the connection layer
  """

  alias FauxRedis.{Command, MockRule}

  @typedoc "Result of rule evaluation."
  @type result :: %{
          response: term(),
          rule_id: reference() | nil,
          rules: [MockRule.t()]
        }

  @doc """
  Applies mock/expectation rules according to the given mode.

  Modes:

    * `:mock_first` – try rules, fall back to `fallback.()` when no match
    * `:mock_only` – try rules, return `{:error, \"ERR unknown command\"}` when no match
    * `:stateful_only` – ignore rules, always call `fallback.()`
  """
  @spec apply([MockRule.t()], Command.t(), :mock_first | :mock_only | :stateful_only, (-> term())) ::
          result()
  def apply(rules, _command, :stateful_only, fallback) do
    %{
      response: fallback.(),
      rule_id: nil,
      rules: rules
    }
  end

  def apply(rules, command, mode, fallback) when mode in [:mock_first, :mock_only] do
    case find_and_realise_rule(rules, command) do
      {:ok, response, new_rules, rule_id} ->
        %{response: response, rule_id: rule_id, rules: new_rules}

      :nomatch ->
        default =
          case mode do
            :mock_first -> fallback.()
            :mock_only -> {:error, "ERR unknown command '#{command.name}'"}
          end

        %{response: default, rule_id: nil, rules: rules}
    end
  end

  @spec find_and_realise_rule([MockRule.t()], Command.t()) ::
          {:ok, term(), [MockRule.t()], reference()} | :nomatch
  defp find_and_realise_rule(rules, command) do
    do_find(rules, command, [])
  end

  defp do_find([], _command, _acc), do: :nomatch

  defp do_find([rule | rest], command, acc) do
    if matches?(rule, command) and under_call_limit?(rule) do
      {response, updated_rule} = realise(rule, command)
      new_rules = Enum.reverse(acc, [updated_rule | rest])
      {:ok, response, new_rules, rule.id}
    else
      do_find(rest, command, [rule | acc])
    end
  end

  @spec matches?(MockRule.t(), Command.t()) :: boolean()
  defp matches?(%MockRule{conn_ids: nil, matcher: matcher}, command) do
    match_matcher(matcher, command)
  end

  defp matches?(
         %MockRule{conn_ids: conn_ids, matcher: matcher},
         %Command{conn_id: conn_id} = command
       ) do
    conn_id in conn_ids and match_matcher(matcher, command)
  end

  defp match_matcher(name, %Command{name: cmd_name}) when is_binary(name) or is_atom(name) do
    normalize(name) == cmd_name
  end

  defp match_matcher({:command, name, args_pattern}, %Command{name: cmd_name, args: args}) do
    normalize(name) == cmd_name and match_args(args_pattern, args)
  end

  defp match_matcher({:fn, fun}, command) when is_function(fun, 1) do
    safe_bool(fun.(command))
  end

  defp match_matcher(_other, _command), do: false

  defp normalize(name) when is_binary(name), do: String.upcase(name)
  defp normalize(name) when is_atom(name), do: name |> Atom.to_string() |> String.upcase()

  defp match_args([], []), do: true

  defp match_args([:any | rest_pattern], [_arg | rest_args]),
    do: match_args(rest_pattern, rest_args)

  defp match_args([%Regex{} = re | rest_pattern], [arg | rest_args]) do
    Regex.match?(re, arg) and match_args(rest_pattern, rest_args)
  end

  defp match_args([expected | rest_pattern], [arg | rest_args]) when is_binary(expected) do
    expected == arg and match_args(rest_pattern, rest_args)
  end

  defp match_args(_pattern, _args), do: false

  defp safe_bool(val) when val in [true, false], do: val
  defp safe_bool(_), do: false

  @spec under_call_limit?(MockRule.t()) :: boolean()
  defp under_call_limit?(%MockRule{max_calls: :infinity}), do: true

  defp under_call_limit?(%MockRule{max_calls: max, times_used: used}) when is_integer(max),
    do: used < max

  @spec realise(MockRule.t(), Command.t()) :: {term(), MockRule.t()}
  defp realise(%MockRule{} = rule, command) do
    {response, new_respond} = realise_response(rule.respond, command)

    updated_rule = %MockRule{
      rule
      | respond: new_respond,
        times_used: rule.times_used + 1
    }

    {response, updated_rule}
  end

  # Sequence responses – use head, keep tail, or repeat last element.
  defp realise_response([single], _command), do: {single, [single]}

  defp realise_response([head | tail], _command), do: {head, tail}

  # Callback function.
  defp realise_response({:fun, fun}, command) when is_function(fun, 1) do
    {fun.(command), {:fun, fun}}
  end

  # Plain response.
  defp realise_response(other, _command), do: {other, other}
end
