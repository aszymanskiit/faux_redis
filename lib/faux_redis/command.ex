defmodule FauxRedis.Command do
  @moduledoc """
  Representation of a single Redis command invocation.

  This struct is used internally by the dispatcher and mocking engine.
  """

  @enforce_keys [:name, :args, :conn_id, :db, :timestamp]
  defstruct [:name, :args, :conn_id, :db, :timestamp, :raw]

  @typedoc "Uppercase command name."
  @type name :: String.t()

  @typedoc "A parsed Redis command."
  @type t :: %__MODULE__{
          name: name(),
          args: [binary()],
          conn_id: non_neg_integer(),
          db: non_neg_integer(),
          timestamp: integer(),
          raw: term()
        }

  @doc """
  Builds a command struct from an array value decoded from RESP.

  The first element is treated as the command name, remaining elements are
  treated as binary arguments.
  """
  @spec from_array([term()], non_neg_integer(), non_neg_integer()) :: t()
  def from_array([name | args], conn_id, db) do
    %__MODULE__{
      name: normalize_name(name),
      args: Enum.map(args, &to_binary/1),
      conn_id: conn_id,
      db: db,
      timestamp: System.system_time(:millisecond),
      raw: [name | args]
    }
  end

  defp normalize_name(name) when is_binary(name), do: String.upcase(name)
  defp normalize_name(name) when is_atom(name), do: name |> Atom.to_string() |> String.upcase()
  defp normalize_name(other), do: other |> to_string() |> String.upcase()

  defp to_binary(bin) when is_binary(bin), do: bin
  defp to_binary(int) when is_integer(int), do: Integer.to_string(int)
  defp to_binary(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp to_binary(other), do: to_string(other)
end
