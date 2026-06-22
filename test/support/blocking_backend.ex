defmodule DurableStash.BlockingBackend do
  @moduledoc """
  `DurableStash.TestBackend` that can pause `put_object` mid-write.

  When armed via `arm/2` with a controller pid and a storage key, a
  `put_object` *for that key* first sends `{:put_blocked, self()}` to the
  controller and waits for `:release` before delegating to the real backend.
  Lets a test prove that a write replies to its caller *before* the storage PUT
  runs — i.e. the LiveView is not blocked on the round-trip. Only the named key
  is held; DurableServer's heartbeat/lifecycle writes (a different key) pass
  through, so the watchdog stays happy.
  """

  @behaviour DurableServer.StorageBackend

  alias DurableStash.TestBackend

  @controller {__MODULE__, :controller}

  def arm(controller, key) when is_pid(controller) and is_binary(key) do
    :persistent_term.put(@controller, {controller, key})
  end

  def disarm, do: :persistent_term.erase(@controller)

  @impl true
  def put_object(name, key, data, opts) do
    case :persistent_term.get(@controller, nil) do
      {controller, ^key} ->
        send(controller, {:put_blocked, self()})

        receive do
          :release -> :ok
        end

      _other ->
        :ok
    end

    TestBackend.put_object(name, key, data, opts)
  end

  @impl true
  defdelegate init_backend(opts), to: TestBackend
  @impl true
  defdelegate ensure_ready(name), to: TestBackend
  @impl true
  defdelegate get_object(name, key, opts), to: TestBackend
  @impl true
  defdelegate list_all_objects_stream(name, prefix, opts), to: TestBackend
  @impl true
  defdelegate delete_object(name, key), to: TestBackend
  @impl true
  defdelegate try_claim(name, key, body), to: TestBackend
  @impl true
  defdelegate update_object(name, key, update_fn, opts), to: TestBackend
  @impl true
  defdelegate encode(name, data), to: TestBackend
  @impl true
  defdelegate decode(name, data), to: TestBackend
end
