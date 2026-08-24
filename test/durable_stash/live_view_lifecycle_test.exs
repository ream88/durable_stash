defmodule DurableStash.LiveViewLifecycleTest do
  # Real LiveView lifecycle against the shared test-app endpoint (started in
  # test_helper.exs). Sessions are isolated per build_conn/0, but the stash
  # supervisor and backend are shared — not async.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint DurableStash.TestApp.Endpoint

  # Threading the conn through get/1 keeps the browser session: live(conn,
  # path) twice would mint two different sessions (response cookies are never
  # recycled).
  defp mount_demo(conn) do
    conn = get(conn, "/demo")
    {:ok, view, html} = live(conn)
    {conn, view, html}
  end

  # The node heartbeat object is rewritten constantly; only session stashes
  # say whether a request touched the store.
  defp stashed_objects do
    DurableStash.TestApp.Backend
    |> DurableStash.TestBackend.dump()
    |> Map.reject(fn {key, _object} -> String.contains?(key, "__nodes/") end)
  end

  test "a stashed assign survives navigation away and back (remount)" do
    {conn, view, html} = mount_demo(build_conn())
    assert html =~ "guest"

    render_click(view, "save", %{"username" => "alice"})

    {_conn, _view, html} = mount_demo(conn)
    assert html =~ "alice"
    refute html =~ "guest"
  end

  test "recovery happens on the disconnected mount too" do
    {conn, view, _html} = mount_demo(build_conn())
    render_click(view, "save", %{"username" => "alice"})

    conn = get(conn, "/demo")
    assert html_response(conn, 200) =~ "alice"
  end

  test "a page render of a reconnect-only view leaves nothing in the store" do
    stored = stashed_objects()

    get(build_conn(), "/draft-only")

    assert stashed_objects() == stored
  end

  test "a reconnect-only view still stashes over a live socket" do
    conn = get(build_conn(), "/draft-only")
    {:ok, view, _html} = live(conn)
    stored = stashed_objects()

    render_click(view, "save", %{"draft" => "half-typed"})

    assert stashed_objects() != stored
  end

  test "a different browser session gets the defaults" do
    {_conn, view, _html} = mount_demo(build_conn())
    render_click(view, "save", %{"username" => "alice"})

    {_conn, _view, html} = mount_demo(build_conn())
    assert html =~ "guest"
    refute html =~ "alice"
  end

  test "reset_stash returns the view to defaults across remounts" do
    {conn, view, _html} = mount_demo(build_conn())
    render_click(view, "save", %{"username" => "alice"})

    {conn, view, _html} = mount_demo(conn)
    render_click(view, "reset", %{})

    {_conn, _view, html} = mount_demo(conn)
    assert html =~ "guest"
    refute html =~ "alice"
  end

  # The reconnect side of the :reconnect scope cannot be exercised here:
  # LiveViewTest's client proxy pins `_mounts` to 0 on every join (it has no
  # rejoin concept). The fake-socket unit tests in adapter_test.exs cover it.
  test ":reconnect keys clear on fresh remounts while :session keys survive" do
    conn = get(build_conn(), "/draft")
    {:ok, view, _html} = live(conn)
    render_click(view, "save", %{"theme" => "dark", "draft" => "half-typed"})

    {:ok, _view, html} = conn |> get("/draft") |> live()
    assert html =~ "dark"
    refute html =~ "half-typed"
  end

  test "two views of one session keep separate slices" do
    conn = build_conn()
    {conn, demo_view, _html} = mount_demo(conn)
    render_click(demo_view, "save", %{"username" => "alice"})

    conn = get(conn, "/other")
    {:ok, other_view, other_html} = live(conn)
    assert other_html =~ "light"

    render_click(other_view, "save", %{"theme" => "dark"})

    {conn, _view, demo_html} = mount_demo(conn)
    assert demo_html =~ "alice"

    conn = get(conn, "/other")
    {:ok, _view, other_html} = live(conn)
    assert other_html =~ "dark"
  end
end
