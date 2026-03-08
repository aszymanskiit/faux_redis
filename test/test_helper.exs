ExUnit.start()

{:ok, _} = Application.ensure_all_started(:faux_redis)
