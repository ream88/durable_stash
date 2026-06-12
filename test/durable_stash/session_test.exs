defmodule DurableStash.SessionTest do
  # DurableServer.Supervisor claims its prefix in :persistent_term, so these
  # tests share global state and cannot run async.
  use ExUnit.Case, async: false

  alias DurableStash.Session
  alias DurableStash.TestBackend

  @view "Elixir.Demo.View"

  setup do
    unique = System.unique_integer([:positive])
    backend = :"session_backend_#{unique}"
    prefix = "session_test_#{unique}/"
    start_supervised!({TestBackend, name: backend})
    %{backend: backend, prefix: prefix, unique: unique}
  end

  test "merge, get_view, fetch_view, reset_view", context do
    supervisor = start_stash_supervisor(context, :sup_a)

    {:ok, {pid, _meta}} = ensure_session(supervisor, "session-1")

    assert Session.fetch_view(pid, @view) == :not_found
    assert Session.get_view(pid, @view) == %{}

    :ok = Session.merge(pid, @view, %{"username" => "alice"})
    :ok = Session.merge(pid, @view, %{"theme" => "dark"})

    assert Session.get_view(pid, @view) == %{
             "username" => "alice",
             "theme" => "dark"
           }

    assert {:ok, %{"vsn" => 1, "data" => _data}} = Session.fetch_view(pid, @view)

    :ok = Session.reset_view(pid, @view)
    assert Session.fetch_view(pid, @view) == :not_found
  end

  test "a write under a new vsn replaces the slice instead of merging", context do
    supervisor = start_stash_supervisor(context, :sup_a)

    {:ok, {pid, _meta}} = ensure_session(supervisor, "session-1")

    :ok = Session.merge(pid, @view, %{"old_key" => "old", "shared" => "v1"}, 1)
    :ok = Session.merge(pid, @view, %{"shared" => "v2"}, 2)

    assert Session.fetch_view(pid, @view) == {:ok, %{"vsn" => 2, "data" => %{"shared" => "v2"}}}
  end

  test "two sessions are isolated", context do
    supervisor = start_stash_supervisor(context, :sup_a)

    {:ok, {pid_one, _meta}} = ensure_session(supervisor, "session-1")
    {:ok, {pid_two, _meta}} = ensure_session(supervisor, "session-2")
    assert pid_one != pid_two

    :ok = Session.merge(pid_one, @view, %{"username" => "alice"})

    assert Session.get_view(pid_two, @view) == %{}
  end

  test "lookup finds a started session", context do
    supervisor = start_stash_supervisor(context, :sup_a)

    {:ok, {pid, _meta}} = ensure_session(supervisor, "session-1")

    assert {found_pid, _meta} = DurableServer.Supervisor.lookup(supervisor, "session-1")
    assert found_pid == pid
    assert DurableServer.Supervisor.lookup(supervisor, "other") == nil
  end

  @tag :integration
  test "state survives a supervisor restart (deploy simulation)", context do
    first_supervisor = start_stash_supervisor(context, :sup_a)

    {:ok, {pid, _meta}} = ensure_session(first_supervisor, "session-1")
    :ok = Session.merge(pid, @view, %{"username" => "alice"})

    :ok = stop_supervised(first_supervisor)
    refute Process.alive?(pid)

    # A real deploy replaces the VM, so the new VM starts with an empty
    # :persistent_term. Simulate that for the prefix claim.
    :persistent_term.erase({DurableServer.Supervisor, :prefix, context.prefix})

    second_supervisor = start_stash_supervisor(context, :sup_b)

    {:ok, {new_pid, _meta}} = ensure_session(second_supervisor, "session-1")
    assert new_pid != pid

    assert Session.get_view(new_pid, @view) == %{
             "username" => "alice"
           }
  end

  defp start_stash_supervisor(%{backend: backend, prefix: prefix, unique: unique}, id) do
    name = :"stash_#{id}_#{unique}"

    start_supervised!(
      {DurableServer.Supervisor,
       name: name, prefix: prefix, backend: {TestBackend, name: backend}}
    )

    name
  end

  defp ensure_session(supervisor, session_key) do
    DurableServer.Supervisor.ensure_started_child(
      supervisor,
      {Session, key: session_key, initial_state: %{}}
    )
  end
end
