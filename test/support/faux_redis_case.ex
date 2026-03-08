defmodule FauxRedis.Case do
  @moduledoc """
  ExUnit case template that spins up an isolated FauxRedis server per test.

  Usage:

      defmodule MyTest do
        use FauxRedis.Case, async: true

        test "example", %{redis_server: server, redis_port: port} do
          {:ok, _rule} = FauxRedis.stub(server, :get, "value")
          assert is_integer(port)
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import FauxRedis.Case
    end
  end

  setup _tags do
    {:ok, server} = FauxRedis.start_link(port: 0, mode: :mock_first)

    on_exit(fn ->
      if Process.alive?(server), do: FauxRedis.stop(server)
    end)

    {:ok,
     %{
       redis_server: server,
       redis_port: FauxRedis.port(server)
     }}
  end

  @doc """
  Convenience wrapper around `FauxRedis.stub/3` that reads the server from
  the test context.
  """
  @spec stub(map(), FauxRedis.matcher(), FauxRedis.response_spec()) ::
          {:ok, reference()}
  def stub(%{redis_server: server}, matcher, response) do
    FauxRedis.stub(server, matcher, response)
  end

  @doc """
  Convenience wrapper around `FauxRedis.expect/3` that reads the server from
  the test context.
  """
  @spec expect(map(), FauxRedis.matcher(), FauxRedis.response_spec()) ::
          {:ok, reference()}
  def expect(%{redis_server: server}, matcher, response) do
    FauxRedis.expect(server, matcher, response)
  end
end
