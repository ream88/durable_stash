import Config

# durable_server force-starts :os_mon, but its probes are only consulted when
# capacity limits (max_cpu/max_memory/max_disk) are configured. Skip the port
# programs locally — they print "[os_mon] ... Erlang has closed" on VM exit.
config :os_mon,
  start_cpu_sup: false,
  start_disksup: false,
  start_memsup: false
