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
