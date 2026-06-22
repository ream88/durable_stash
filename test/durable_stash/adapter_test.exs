defmodule DurableStash.AdapterTest do
  # Shares :persistent_term prefix claims and tweaks app env — not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DurableStash.Session
  alias DurableStash.TestBackend
  alias Phoenix.LiveView.Socket

  defmodule FakeView do
  end

  defmodule OtherFakeView do
  end

  setup do
    unique = System.unique_integer([:positive])
    backend = :"adapter_backend_#{unique}"
    supervisor = :"adapter_sup_#{unique}"
    start_supervised!({TestBackend, name: backend})

    start_supervised!(
      {DurableServer.Supervisor,
       name: supervisor, prefix: "adapter_test_#{unique}/", backend: {TestBackend, name: backend}}
    )

    %{supervisor: supervisor, backend: backend, sid: "sid-#{unique}"}
  end

  defp fake_socket(view) do
    %Socket{view: view, assigns: %{__changed__: %{}}}
  end

  defp fake_connected_socket(view, mounts) do
    %Socket{
      view: view,
      transport_pid: self(),
      private: %{connect_params: %{"_mounts" => mounts}},
      assigns: %{__changed__: %{}}
    }
  end

  defp init(socket, sid, supervisor, opts) do
    base_opts = [supervisor: supervisor]

    DurableStash.init_stash(socket, %{"sid" => sid}, Keyword.merge(base_opts, opts))
  end

  describe "init_stash/3 option parsing" do
    test "accepts bare atoms and :session scope, rejects the rest", context do
      socket = fake_socket(FakeView)

      assert %Socket{} =
               init(socket, context.sid, context.supervisor, stored_keys: [:plain, scoped: :session, draft: :reconnect])

      assert_raise ArgumentError, ~r/:permanent scope is not yet supported/, fn ->
        init(socket, context.sid, context.supervisor, stored_keys: [theme: :permanent])
      end

      assert_raise ArgumentError, ~r/invalid stored_keys entry/, fn ->
        init(socket, context.sid, context.supervisor, stored_keys: ["nope"])
      end
    end

    test "rejects a non-function migrate", context do
      assert_raise ArgumentError, ~r/:migrate must be a 2-arity function/, fn ->
        init(fake_socket(FakeView), context.sid, context.supervisor,
          stored_keys: [:host],
          migrate: :not_a_fun
        )
      end
    end
  end

  describe "stash + recover round trip" do
    test "a second socket in the same session recovers the stashed assigns", context do
      FakeView
      |> fake_socket()
      |> init(context.sid, context.supervisor, stored_keys: [:host, :count])
      |> Phoenix.Component.assign(host: "https://example.test", count: 3)
      |> DurableStash.stash()

      socket_b =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:host, :count])
        |> Phoenix.Component.assign(host: "unset", count: 0)

      assert {:recovered, recovered} = DurableStash.recover_state(socket_b)
      assert recovered.assigns.host == "https://example.test"
      assert recovered.assigns.count == 3
    end

    test "recovers on every mount — nothing stashed means :not_found", context do
      socket =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:host])

      assert {:not_found, ^socket} = DurableStash.recover_state(socket)
    end

    test "values are normalized through JSON: atom-keyed maps come back string-keyed",
         context do
      socket_a =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:settings])
        |> Phoenix.Component.assign(settings: %{retries: 2})
        |> DurableStash.stash()

      assert {:recovered, recovered} =
               socket_a
               |> Map.put(:assigns, %{__changed__: %{}})
               |> DurableStash.recover_state()

      assert recovered.assigns.settings == %{"retries" => 2}
    end

    test "views are isolated within one session", context do
      FakeView
      |> fake_socket()
      |> init(context.sid, context.supervisor, stored_keys: [:host])
      |> Phoenix.Component.assign(host: "https://example.test")
      |> DurableStash.stash()

      other_socket =
        OtherFakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:host])

      assert {:not_found, _socket} = DurableStash.recover_state(other_socket)
    end

    test "sessions are isolated", context do
      FakeView
      |> fake_socket()
      |> init(context.sid, context.supervisor, stored_keys: [:host])
      |> Phoenix.Component.assign(host: "https://example.test")
      |> DurableStash.stash()

      other_session_socket =
        FakeView
        |> fake_socket()
        |> init("other-#{context.sid}", context.supervisor, stored_keys: [:host])

      assert {:not_found, _socket} = DurableStash.recover_state(other_session_socket)
    end
  end

  describe "per-key diffs" do
    test "an unchanged stash is a no-op and disjoint keys merge without lost updates",
         context do
      socket_a =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:host, :theme])
        |> Phoenix.Component.assign(host: "h1", theme: "t1")
        |> DurableStash.stash()

      assert DurableStash.stash(socket_a) == socket_a

      {:recovered, socket_b} =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:host, :theme])
        |> DurableStash.recover_state()

      # Tab B changes only :theme, tab A changes only :host — neither write
      # may clobber the other key.
      socket_b
      |> Phoenix.Component.assign(theme: "t2")
      |> DurableStash.stash()

      socket_a
      |> Phoenix.Component.assign(host: "h2")
      |> DurableStash.stash()

      {:recovered, final} =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:host, :theme])
        |> DurableStash.recover_state()

      assert final.assigns.host == "h2"
      assert final.assigns.theme == "t2"
    end
  end

  describe ":reconnect scope" do
    @mixed_keys [theme: :session, draft: :reconnect]

    test "recovers on reconnects, clears on fresh connected mounts", context do
      FakeView
      |> fake_connected_socket(0)
      |> init(context.sid, context.supervisor, stored_keys: @mixed_keys)
      |> Phoenix.Component.assign(theme: "dark", draft: "half-typed")
      |> DurableStash.stash()

      {:recovered, rejoined} =
        FakeView
        |> fake_connected_socket(1)
        |> init(context.sid, context.supervisor, stored_keys: @mixed_keys)
        |> DurableStash.recover_state()

      assert rejoined.assigns.theme == "dark"
      assert rejoined.assigns.draft == "half-typed"

      {:recovered, fresh} =
        FakeView
        |> fake_connected_socket(0)
        |> init(context.sid, context.supervisor, stored_keys: @mixed_keys)
        |> DurableStash.recover_state()

      assert fresh.assigns.theme == "dark"
      refute Map.has_key?(fresh.assigns, :draft)

      # The fresh mount dropped the draft from the store itself.
      storage_key = fresh.private.durable_stash.storage_key

      {:ok, {pid, _meta}} =
        DurableServer.Supervisor.ensure_started_child(
          context.supervisor,
          {Session, key: storage_key, initial_state: %{}}
        )

      assert Session.get_view(pid, Atom.to_string(FakeView)) == %{"theme" => "dark"}
    end

    test "a disconnected mount filters reconnect keys without dropping them", context do
      FakeView
      |> fake_connected_socket(0)
      |> init(context.sid, context.supervisor, stored_keys: @mixed_keys)
      |> Phoenix.Component.assign(theme: "dark", draft: "half-typed")
      |> DurableStash.stash()

      {:recovered, disconnected} =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: @mixed_keys)
        |> DurableStash.recover_state()

      assert disconnected.assigns.theme == "dark"
      refute Map.has_key?(disconnected.assigns, :draft)

      # No client to rejoin from a disconnected render, so the draft stays
      # stored for the connected mount that follows.
      storage_key = disconnected.private.durable_stash.storage_key

      {:ok, {pid, _meta}} =
        DurableServer.Supervisor.ensure_started_child(
          context.supervisor,
          {Session, key: storage_key, initial_state: %{}}
        )

      assert Session.get_view(pid, Atom.to_string(FakeView)) == %{
               "theme" => "dark",
               "draft" => "half-typed"
             }
    end
  end

  describe "vsn and migrate" do
    test "a vsn mismatch without migrate discards to defaults", context do
      FakeView
      |> fake_socket()
      |> init(context.sid, context.supervisor, stored_keys: [:host], vsn: 1)
      |> Phoenix.Component.assign(host: "old")
      |> DurableStash.stash()

      bumped_socket =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:host], vsn: 2)

      assert {:not_found, _socket} = DurableStash.recover_state(bumped_socket)
    end

    test "migrate transforms the stored data and writes it back under the new vsn",
         context do
      FakeView
      |> fake_socket()
      |> init(context.sid, context.supervisor, stored_keys: [:host], vsn: 1)
      |> Phoenix.Component.assign(host: "example.test")
      |> DurableStash.stash()

      migrate = fn 1, %{"host" => host} -> %{"host" => "https://" <> host} end

      {:recovered, recovered} =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:host], vsn: 2, migrate: migrate)
        |> DurableStash.recover_state()

      assert recovered.assigns.host == "https://example.test"

      view_name = Atom.to_string(FakeView)
      storage_key = recovered.private.durable_stash.storage_key

      {:ok, {pid, _meta}} =
        DurableServer.Supervisor.ensure_started_child(
          context.supervisor,
          {Session, key: storage_key, initial_state: %{}}
        )

      assert Session.fetch_view(pid, view_name) ==
               {:ok, %{"vsn" => 2, "data" => %{"host" => "https://example.test"}}}
    end
  end

  describe "JSON-safety guards" do
    test "raises when configured to (test default)", context do
      socket =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:bad])
        |> Phoenix.Component.assign(bad: {:a, :tuple})

      assert_raise ArgumentError, ~r/not JSON-safe/, fn -> DurableStash.stash(socket) end
    end

    test "logs and skips the offending key in :log mode", context do
      Application.put_env(:durable_stash, :on_invalid_value, :log)
      on_exit(fn -> Application.put_env(:durable_stash, :on_invalid_value, :raise) end)

      socket =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:good, :bad])
        |> Phoenix.Component.assign(good: "kept", bad: {:a, :tuple})

      log =
        capture_log(fn ->
          DurableStash.stash(socket)
        end)

      assert log =~ "not JSON-safe"

      {:recovered, recovered} =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:good, :bad])
        |> DurableStash.recover_state()

      assert recovered.assigns.good == "kept"
      refute Map.has_key?(recovered.assigns, :bad)
    end
  end

  describe "degraded contexts never crash the LiveView" do
    test "missing sid: stash and reset are no-ops, recover returns :error", context do
      log =
        capture_log(fn ->
          socket =
            DurableStash.init_stash(fake_socket(FakeView), %{},
              supervisor: context.supervisor,
              stored_keys: [:host]
            )

          socket = Phoenix.Component.assign(socket, host: "value")

          assert DurableStash.stash(socket) == socket
          assert DurableStash.reset_stash(socket) == socket
          assert {:error, ^socket} = DurableStash.recover_state(socket)
        end)

      assert log =~ "ensure_session_id"
    end

    test "unreachable supervisor: stash logs and returns the socket", context do
      socket =
        FakeView
        |> fake_socket()
        |> init(context.sid, :nonexistent_supervisor, stored_keys: [:host])
        |> Phoenix.Component.assign(host: "value")

      log =
        capture_log(fn ->
          assert DurableStash.stash(socket) == socket
          assert {:error, _socket} = DurableStash.recover_state(socket)
        end)

      assert log =~ "[DurableStash]"
    end
  end

  describe "reset_stash/1" do
    test "clears the view slice", context do
      socket =
        FakeView
        |> fake_socket()
        |> init(context.sid, context.supervisor, stored_keys: [:host])
        |> Phoenix.Component.assign(host: "value")
        |> DurableStash.stash()

      DurableStash.reset_stash(socket)

      assert {:not_found, _socket} =
               FakeView
               |> fake_socket()
               |> init(context.sid, context.supervisor, stored_keys: [:host])
               |> DurableStash.recover_state()
    end
  end
end
