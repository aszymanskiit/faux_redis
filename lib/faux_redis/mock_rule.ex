defmodule FauxRedis.MockRule do
  @moduledoc """
  Definition of a single mock or expectation rule.

  Rules are stored and evaluated by `FauxRedis.MockEngine`. Users normally
  create rules via the high-level `FauxRedis.stub/2`, `stub/3` and
  `FauxRedis.expect/3` functions.
  """

  alias FauxRedis.Command

  @typedoc "Rule type: stub or expectation."
  @type kind :: :stub | :expect

  @typedoc "Matcher used to decide which commands a rule applies to."
  @type matcher ::
          FauxRedis.matcher()
          | {:command, FauxRedis.command_name(), [binary() | :any | Regex.t()]}
          | {:fn, (Command.t() -> boolean())}

  @typedoc "Response specification; see `FauxRedis.response_spec/0`."
  @type response_spec :: FauxRedis.response_spec()

  @typedoc """
  A mock rule.

  Fields:

    * `id` – unique reference
    * `kind` – `:stub` or `:expect`
    * `matcher` – how commands are matched
    * `respond` – response specification (or list of them for sequences)
    * `max_calls` – maximum times this rule may be used (default: `:infinity`)
    * `times_used` – how many times the rule has been applied
    * `conn_ids` – optional list of allowed connection ids
  """
  @type t :: %__MODULE__{
          id: reference(),
          kind: kind(),
          matcher: matcher(),
          respond: response_spec(),
          max_calls: non_neg_integer() | :infinity,
          times_used: non_neg_integer(),
          conn_ids: nil | [non_neg_integer()]
        }

  @enforce_keys [:id, :kind, :matcher, :respond]
  defstruct [:id, :kind, :matcher, :respond, max_calls: :infinity, times_used: 0, conn_ids: nil]

  @doc """
  Builds a rule from a keyword list.

  Supported options:

    * `:matcher` – required matcher
    * `:respond` – required response specification
    * `:kind` – `:stub` or `:expect`
    * `:max_calls` – maximum times this rule may be used
    * `:conn_id` – only apply to the given connection id
    * `:conn_ids` – only apply to any of the given connection ids
  """
  @spec build(kind(), Keyword.t()) :: t()
  def build(kind, opts) do
    matcher = Keyword.fetch!(opts, :matcher)
    respond = Keyword.fetch!(opts, :respond)

    conn_ids =
      case {Keyword.get(opts, :conn_id), Keyword.get(opts, :conn_ids)} do
        {nil, nil} -> nil
        {id, nil} when is_integer(id) -> [id]
        {nil, ids} when is_list(ids) -> ids
        {id, ids} when is_integer(id) and is_list(ids) -> [id | ids]
        _ -> nil
      end

    %__MODULE__{
      id: make_ref(),
      kind: kind,
      matcher: matcher,
      respond: respond,
      max_calls: Keyword.get(opts, :max_calls, :infinity),
      conn_ids: conn_ids
    }
  end
end
