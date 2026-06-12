# durable_server and its group dep are very chatty at :info/:debug;
# phoenix logs every dispatch and phoenix_live_view every channel reply at :debug
Logger.put_application_level(:durable_server, :warning)
Logger.put_application_level(:group, :warning)
Logger.put_application_level(:phoenix, :info)
Logger.put_application_level(:phoenix_live_view, :info)

Application.put_env(:live_stash, :adapters, [DurableStash])
Application.put_env(:durable_stash, :on_invalid_value, :raise)

Application.put_env(:durable_stash, DurableStash.TestApp.Endpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("durable_stash_secret_key_base_", 3),
  live_view: [signing_salt: "ds_lv_salt"],
  pubsub_server: DurableStash.TestApp.PubSub,
  server: false
)

test_app_children = [
  {Phoenix.PubSub, name: DurableStash.TestApp.PubSub},
  {DurableStash.TestBackend, name: DurableStash.TestApp.Backend},
  {DurableServer.Supervisor,
   name: DurableStash.TestApp.StashSupervisor,
   prefix: "test_app/",
   backend: {DurableStash.TestBackend, name: DurableStash.TestApp.Backend}},
  DurableStash.TestApp.Endpoint
]

{:ok, _test_app} =
  Supervisor.start_link(test_app_children,
    strategy: :one_for_one,
    name: DurableStash.TestApp.Supervisor
  )

ExUnit.start()
