import Config

config :faux_redis,
  # Reserved for future configuration; the library is intentionally light on
  # global settings to keep test behaviour explicit.
  default_mode: :mock_first
