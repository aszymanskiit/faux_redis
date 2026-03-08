defmodule FauxRedis.Application do
  @moduledoc """
  OTP application entry point for `:faux_redis`.

  The application itself is intentionally minimal – it only starts a `Registry`
  used for optional server naming. Individual Redis dummy servers are started
  via `FauxRedis.start_link/1` or as children under your own supervision
  tree using `FauxRedis.child_spec/1`.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: FauxRedis.ServerRegistry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FauxRedis.Supervisor)
  end
end
