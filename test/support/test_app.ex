defmodule DurableStash.TestApp.DemoLive do
  @moduledoc false
  use Phoenix.LiveView

  use LiveStash,
    adapter: DurableStash,
    stored_keys: [:username],
    supervisor: DurableStash.TestApp.StashSupervisor

  @default_username "guest"

  def mount(_params, _session, socket) do
    socket = assign(socket, :username, @default_username)
    {_status, socket} = LiveStash.recover_state(socket)
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="username">{@username}</div>
    """
  end

  def handle_event("save", %{"username" => username}, socket) do
    socket = assign(socket, :username, username)
    {:noreply, LiveStash.stash(socket)}
  end

  def handle_event("reset", _params, socket) do
    socket = LiveStash.reset_stash(socket)
    socket = assign(socket, :username, @default_username)
    {:noreply, socket}
  end
end

defmodule DurableStash.TestApp.OtherLive do
  @moduledoc false
  use Phoenix.LiveView

  use LiveStash,
    adapter: DurableStash,
    stored_keys: [:theme],
    supervisor: DurableStash.TestApp.StashSupervisor

  def mount(_params, _session, socket) do
    socket = assign(socket, :theme, "light")
    {_status, socket} = LiveStash.recover_state(socket)
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="theme">{@theme}</div>
    """
  end

  def handle_event("save", %{"theme" => theme}, socket) do
    socket = assign(socket, :theme, theme)
    {:noreply, LiveStash.stash(socket)}
  end
end

defmodule DurableStash.TestApp.DraftLive do
  @moduledoc false
  use Phoenix.LiveView

  use LiveStash,
    adapter: DurableStash,
    stored_keys: [theme: :session, draft: :reconnect],
    supervisor: DurableStash.TestApp.StashSupervisor

  def mount(_params, _session, socket) do
    socket = assign(socket, theme: "light", draft: "empty")
    {_status, socket} = LiveStash.recover_state(socket)
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="theme">{@theme}</div>
    <div id="draft">{@draft}</div>
    """
  end

  def handle_event("save", params, socket) do
    socket = assign(socket, theme: params["theme"], draft: params["draft"])
    {:noreply, LiveStash.stash(socket)}
  end
end

defmodule DurableStash.TestApp.Router do
  @moduledoc false
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:ensure_session_id)
  end

  scope "/", DurableStash.TestApp do
    pipe_through(:browser)

    live_session :default, root_layout: false do
      live("/demo", DemoLive)
      live("/other", OtherLive)
      live("/draft", DraftLive)
    end
  end

  defp ensure_session_id(conn, _opts) do
    if Plug.Conn.get_session(conn, "sid") do
      conn
    else
      sid = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      Plug.Conn.put_session(conn, "sid", sid)
    end
  end
end

defmodule DurableStash.TestApp.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :durable_stash

  @session_options [
    store: :cookie,
    key: "_durable_stash_test",
    signing_salt: "ds_test_salt",
    same_site: "Lax"
  ]

  plug(Plug.Session, @session_options)
  plug(DurableStash.TestApp.Router)
end
