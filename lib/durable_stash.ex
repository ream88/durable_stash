defmodule DurableStash do
  @moduledoc """
  Durable, browser-session-scoped server state for Phoenix LiveView.

  `DurableStash` is a [LiveStash](https://hex.pm/packages/live_stash) adapter
  backed by [DurableServer](https://hex.pm/packages/durable_server): one
  durable process per browser session, persisted to S3-compatible object
  storage, shared by every LiveView of that session. State survives live
  navigation, WebSocket reconnects, LiveView crashes, and redeploys — and
  dies with the browser session.

  ## Usage

      defmodule MyAppWeb.SomeLive do
        use MyAppWeb, :live_view
        use LiveStash, adapter: DurableStash, stored_keys: [:count, :username]

        def mount(_params, _session, socket) do
          socket = assign(socket, count: 0, username: nil)
          {_status, socket} = LiveStash.recover_state(socket)
          {:ok, socket}
        end
      end

  Call `LiveStash.recover_state/1` in `mount/3` *after* assigning defaults
  (recovered values overwrite them), and `LiveStash.stash/1` whenever a
  stored assign changes — or pass `auto_stash: true`.

  Unlike the stock ETS adapter, `DurableStash` recovers on **every** mount —
  fresh navigations included — and never deletes the stash on mount. State is
  keyed by the browser session, not by the socket.

  ## Setup

  1. Register the adapter and configure the backend:

         config :live_stash, adapters: [DurableStash]

         config :durable_stash,
           backend: {DurableServer.Backends.ObjectStore, bucket: "...", ...},
           prefix: "durable_stash/",
           secret: "some-stable-secret"

     With that config, `LiveStash.Application` starts the DurableServer
     supervisor automatically through `child_spec/1`. Alternatively, run your
     own `DurableServer.Supervisor` and point the adapter at it with the
     `:supervisor` option.

  2. Put a session id into the cookie session, in the `:browser` pipeline
     after `plug :fetch_session`:

         plug :ensure_session_id

         defp ensure_session_id(conn, _opts) do
           if get_session(conn, "sid") do
             conn
           else
             sid = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
             put_session(conn, "sid", sid)
           end
         end

  ## Scopes

  Not all state wants the same recovery policy. Each stored key declares a
  scope:

      use LiveStash, adapter: DurableStash,
        stored_keys: [
          theme: :session,    # recover on every mount (the default)
          draft: :reconnect   # recover only on reconnects; cleared on fresh mounts
        ]

    * `:session` — recovered on every mount: live navigation, reconnects,
      crashes, redeploys. Right for settings the user expects to stick.
    * `:reconnect` — recovered only when the client *rejoins* an existing
      view (`_mounts > 0`): Wi-Fi drops, LiveView crashes, and redeploys —
      the browser stays on the page through all of these. A fresh navigation
      to the view clears the stored values, so starting a "new thing" starts
      blank. Right for in-progress form drafts.

  ## Options (via `use LiveStash, adapter: DurableStash, ...`)

    * `:stored_keys` (required) — assigns to persist. Bare atoms mean
      `:session` scope; see *Scopes* above for `:reconnect`. `:permanent` is
      reserved and raises for now.
    * `:vsn` (default `1`) — version of this view's stored shape. On
      recovery, a stored slice with a different vsn is discarded to defaults
      unless `:migrate` is given.
    * `:migrate` — 2-arity function `(old_vsn, data) :: data` receiving the
      stored string-keyed data map and returning the migrated one. The
      migrated set is written back under the new vsn.
    * `:supervisor` — DurableServer supervisor name (default
      `config :durable_stash, :supervisor_name`, falling back to
      `DurableStash.Supervisor`).
    * `:secret` — mixed into the storage-key hash (default
      `config :durable_stash, :secret`).
    * `:session_id_key` — cookie-session key holding the session id
      (default `"sid"`).

  ## What's storable

  JSON-safe values only: no structs, tuples, pids, or functions; maps come
  back with string keys. Offending values are skipped with a logged error, or
  raise when `config :durable_stash, on_invalid_value: :raise` is set
  (recommended for dev and test). Values are normalized through a JSON
  round-trip at stash time, so what you recover in dev is byte-for-byte what
  you'd recover after a redeploy in prod.
  """

  @behaviour LiveStash.Adapter

  require Logger

  alias DurableStash.Session
  alias Phoenix.Component
  alias Phoenix.LiveView

  defmodule Context do
    @moduledoc false
    defstruct supervisor: nil,
              storage_key: nil,
              view: nil,
              stored_keys: [],
              vsn: 1,
              migrate: nil,
              fingerprints: %{},
              reconnected?: false
  end

  @private_key :durable_stash
  @default_secret "durable_stash"
  @default_session_id_key "sid"

  ## LiveStash.Adapter callbacks

  @impl true
  def init_stash(socket, session, opts) do
    stored_keys = parse_stored_keys!(Keyword.fetch!(opts, :stored_keys))
    vsn = Keyword.get(opts, :vsn, 1)
    migrate = parse_migrate!(Keyword.get(opts, :migrate))

    supervisor =
      Keyword.get(opts, :supervisor) ||
        Application.get_env(:durable_stash, :supervisor_name, DurableStash.Supervisor)

    secret =
      Keyword.get(opts, :secret) ||
        Application.get_env(:durable_stash, :secret, @default_secret)

    session_id_key = Keyword.get(opts, :session_id_key, @default_session_id_key)

    context = %Context{
      supervisor: supervisor,
      storage_key: derive_storage_key(session, session_id_key, secret),
      view: view_name(socket),
      stored_keys: stored_keys,
      vsn: vsn,
      migrate: migrate,
      reconnected?: reconnected?(socket)
    }

    clear_stale_reconnect_keys(socket, context)

    LiveView.put_private(socket, @private_key, context)
  end

  @impl true
  def stash(socket) do
    case operable_context(socket) do
      {:ok, context} -> do_stash(socket, context)
      :error -> socket
    end
  end

  @impl true
  def recover_state(socket) do
    case operable_context(socket) do
      {:ok, context} -> do_recover(socket, context)
      :error -> {:error, socket}
    end
  end

  @impl true
  def reset_stash(socket) do
    case operable_context(socket) do
      {:ok, context} -> do_reset(socket, context)
      :error -> socket
    end
  end

  @doc """
  Starts the DurableServer supervisor from `:durable_stash` config when a
  `:backend` is configured; otherwise starts an empty, harmless supervisor.
  Invoked automatically by `LiveStash.Application` for registered adapters.
  """
  @impl true
  def child_spec(_args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_configured_supervisor, []},
      type: :supervisor
    }
  end

  @doc false
  def start_configured_supervisor do
    children =
      case Application.get_env(:durable_stash, :backend) do
        nil ->
          []

        backend ->
          supervisor_opts = Application.get_env(:durable_stash, :supervisor_opts, [])

          [
            {DurableServer.Supervisor,
             [
               name:
                 Application.get_env(:durable_stash, :supervisor_name, DurableStash.Supervisor),
               prefix: Application.get_env(:durable_stash, :prefix, "durable_stash/"),
               backend: backend
             ] ++ supervisor_opts}
          ]
      end

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  ## Stash

  defp do_stash(socket, %Context{} = context) do
    {changes, fingerprints} = changed_entries(socket.assigns, context)

    if changes == %{} do
      socket
    else
      case call_session(context, &Session.merge(&1, context.view, changes, context.vsn)) do
        :ok ->
          put_context(socket, %{context | fingerprints: fingerprints})

        {:error, reason} ->
          Logger.error("[DurableStash] stash failed for #{context.view}: #{inspect(reason)}")
          socket
      end
    end
  end

  defp changed_entries(assigns, %Context{} = context) do
    context.stored_keys
    |> Enum.map(fn {key, _scope} -> key end)
    |> Enum.reduce({%{}, context.fingerprints}, fn key, {changes, fingerprints} ->
      with {:ok, value} <- Map.fetch(assigns, key),
           {:ok, encoded} <- encode_value(key, value) do
        name = Atom.to_string(key)
        fingerprint = fingerprint(encoded)

        if fingerprints[name] == fingerprint do
          {changes, fingerprints}
        else
          {Map.put(changes, name, JSON.decode!(encoded)),
           Map.put(fingerprints, name, fingerprint)}
        end
      else
        :error -> {changes, fingerprints}
        {:skip, _key} -> {changes, fingerprints}
      end
    end)
  end

  defp encode_value(key, value) do
    {:ok, JSON.encode!(value)}
  rescue
    error ->
      message =
        "[DurableStash] value for #{inspect(key)} is not JSON-safe " <>
          "(no structs, tuples, pids, or functions): #{Exception.message(error)}"

      case Application.get_env(:durable_stash, :on_invalid_value, :log) do
        :raise ->
          reraise ArgumentError.exception(message), __STACKTRACE__

        _log ->
          Logger.error(message)
          {:skip, key}
      end
  end

  ## Recover

  defp do_recover(socket, %Context{} = context) do
    case call_session(context, &Session.fetch_view(&1, context.view)) do
      :not_found ->
        {:not_found, socket}

      {:ok, %{"vsn" => stored_vsn, "data" => data}} ->
        recover_slice(socket, context, stored_vsn, data)

      {:error, reason} ->
        Logger.error("[DurableStash] recover failed for #{context.view}: #{inspect(reason)}")
        {:error, socket}
    end
  end

  defp recover_slice(socket, %Context{vsn: vsn} = context, vsn, data) do
    apply_recovered(socket, context, data)
  end

  defp recover_slice(socket, %Context{migrate: nil}, _stored_vsn, _data) do
    # Version mismatch without a migration: UI-grade state, discard to
    # defaults. The next stash overwrites the slice under the current vsn.
    {:not_found, socket}
  end

  defp recover_slice(socket, %Context{} = context, stored_vsn, data) do
    migrated = context.migrate.(stored_vsn, data)

    case apply_recovered(socket, context, migrated) do
      {:recovered, recovered_socket} ->
        write_back_migrated(recovered_socket, migrated)

      other ->
        other
    end
  rescue
    error ->
      Logger.error(
        "[DurableStash] migrate from vsn #{stored_vsn} failed for #{context.view}: " <>
          Exception.message(error)
      )

      {:error, socket}
  end

  # Persist the full migrated set under the new vsn so the slice can never
  # end up as a mix of old- and new-shape keys.
  defp write_back_migrated(socket, migrated) do
    context = socket.private[@private_key]
    restored = Map.take(migrated, Enum.map(recoverable_keys(context), &Atom.to_string/1))

    case call_session(context, &Session.merge(&1, context.view, restored, context.vsn)) do
      :ok ->
        {:recovered, socket}

      {:error, reason} ->
        Logger.error(
          "[DurableStash] migrated write-back failed for #{context.view}: #{inspect(reason)}"
        )

        {:recovered, socket}
    end
  end

  defp apply_recovered(socket, %Context{} = context, data) do
    {recovered, fingerprints} =
      context
      |> recoverable_keys()
      |> Enum.reduce({%{}, context.fingerprints}, fn key, {recovered, fingerprints} ->
        # Atom keys come from the declared whitelist — never String.to_atom
        # on stored input.
        case Map.fetch(data, Atom.to_string(key)) do
          {:ok, value} ->
            fingerprint = fingerprint(JSON.encode!(value))

            {Map.put(recovered, key, value),
             Map.put(fingerprints, Atom.to_string(key), fingerprint)}

          :error ->
            {recovered, fingerprints}
        end
      end)

    if recovered == %{} do
      {:not_found, socket}
    else
      socket
      |> Component.assign(recovered)
      |> put_context(%{context | fingerprints: fingerprints})
      |> then(&{:recovered, &1})
    end
  end

  ## Reset

  defp do_reset(socket, %Context{} = context) do
    case call_session(context, &Session.reset_view(&1, context.view)) do
      :ok ->
        put_context(socket, %{context | fingerprints: %{}})

      {:error, reason} ->
        Logger.error("[DurableStash] reset failed for #{context.view}: #{inspect(reason)}")
        socket
    end
  end

  ## Session access

  defp call_session(%Context{} = context, fun) do
    case DurableServer.Supervisor.ensure_started_child(
           context.supervisor,
           {Session, key: context.storage_key, initial_state: %{}}
         ) do
      {:ok, {pid, _meta}} -> fun.(pid)
      {:error, reason} -> {:error, reason}
      :ignore -> {:error, :ignore}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  ## Context plumbing

  defp operable_context(socket) do
    case socket.private[@private_key] do
      %Context{} = context ->
        if operable?(context), do: {:ok, context}, else: :error

      nil ->
        Logger.error(
          "[DurableStash] no stash context on socket — did you `use LiveStash, adapter: DurableStash`?"
        )

        :error
    end
  end

  defp operable?(%Context{storage_key: storage_key, view: view}) do
    is_binary(storage_key) and is_binary(view)
  end

  defp put_context(socket, %Context{} = context) do
    LiveView.put_private(socket, @private_key, context)
  end

  defp derive_storage_key(session, session_id_key, secret) do
    case session do
      %{^session_id_key => sid} when is_binary(sid) ->
        :sha256
        |> :crypto.hash(sid <> secret)
        |> Base.url_encode64(padding: false)

      _session ->
        Logger.error(
          "[DurableStash] no #{inspect(session_id_key)} in the cookie session — " <>
            "add the ensure_session_id plug to your :browser pipeline (see the DurableStash docs)"
        )

        nil
    end
  end

  defp view_name(%{view: view}) when is_atom(view) and not is_nil(view), do: Atom.to_string(view)

  defp view_name(_socket) do
    Logger.error("[DurableStash] socket has no view — cannot scope the stash")
    nil
  end

  defp keys_for_scope(%Context{stored_keys: stored_keys}, scope) do
    for {key, ^scope} <- stored_keys, do: key
  end

  defp recoverable_keys(%Context{reconnected?: true} = context) do
    keys_for_scope(context, :session) ++ keys_for_scope(context, :reconnect)
  end

  defp recoverable_keys(%Context{} = context) do
    keys_for_scope(context, :session)
  end

  # A reconnect (Wi-Fi drop, LiveView crash, deploy) rejoins the same client
  # view, so `_mounts` is positive. A fresh navigation mounts at zero.
  defp reconnected?(socket) do
    match?(%{"_mounts" => mounts} when is_integer(mounts) and mounts > 0, connect_params(socket))
  end

  defp connect_params(socket) do
    if LiveView.connected?(socket) do
      LiveView.get_connect_params(socket) || %{}
    else
      %{}
    end
  rescue
    # get_connect_params is only available while mounting; treat anything
    # else as a fresh mount.
    _error -> %{}
  end

  # Stock LiveStash semantics for :reconnect keys: a fresh mount starts the
  # task over, so the stored values must go — otherwise a crash right after
  # navigating here would resurrect a stale draft.
  defp clear_stale_reconnect_keys(socket, %Context{} = context) do
    reconnect_keys = keys_for_scope(context, :reconnect)

    if reconnect_keys != [] and LiveView.connected?(socket) and not context.reconnected? and
         operable?(context) do
      keys = Enum.map(reconnect_keys, &Atom.to_string/1)

      case call_session(context, &Session.drop(&1, context.view, keys)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[DurableStash] clearing reconnect keys failed for #{context.view}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  defp fingerprint(encoded) when is_binary(encoded) do
    :crypto.hash(:sha256, encoded)
  end

  ## Option parsing — config errors should be loud, so these raise.

  defp parse_stored_keys!(stored_keys) when is_list(stored_keys) do
    Enum.map(stored_keys, fn
      key when is_atom(key) ->
        {key, :session}

      {key, scope} when is_atom(key) and scope in [:session, :reconnect] ->
        {key, scope}

      {key, :permanent} when is_atom(key) ->
        raise ArgumentError,
              "[DurableStash] the :permanent scope is not yet supported (key #{inspect(key)})"

      other ->
        raise ArgumentError,
              "[DurableStash] invalid stored_keys entry: #{inspect(other)} — " <>
                "expected an atom, `{atom, :session}`, or `{atom, :reconnect}`"
    end)
  end

  defp parse_stored_keys!(other) do
    raise ArgumentError, "[DurableStash] stored_keys must be a list, got: #{inspect(other)}"
  end

  defp parse_migrate!(nil), do: nil
  defp parse_migrate!(migrate) when is_function(migrate, 2), do: migrate

  defp parse_migrate!(other) do
    raise ArgumentError,
          "[DurableStash] :migrate must be a 2-arity function (old_vsn, data), got: #{inspect(other)}"
  end
end
