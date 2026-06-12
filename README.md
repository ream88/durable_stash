# DurableStash

Durable, browser-session-scoped server state for Phoenix LiveView.

DurableStash is a [LiveStash](https://github.com/software-mansion-labs/live-stash)
adapter backed by [DurableServer](https://hex.pm/packages/durable_server): one
durable process per browser session, persisted to S3-compatible object storage,
shared by every LiveView of that session.

State survives:

- live navigation (unlike the stock ETS adapter, recovery happens on **every**
  mount, not just reconnects)
- WebSocket reconnects (Wi-Fi hiccups)
- LiveView crashes
- **redeploys** — state lives in object storage, not BEAM memory

State dies with the browser session: cleared cookies, another browser, or TTL
expiry mean defaults.

## Usage

```elixir
defmodule MyAppWeb.SomeLive do
  use MyAppWeb, :live_view
  use LiveStash, adapter: DurableStash, stored_keys: [:count, :username]

  def mount(_params, _session, socket) do
    socket = assign(socket, count: 0, username: nil)
    {_status, socket} = LiveStash.recover_state(socket)
    {:ok, socket}
  end

  def handle_event("increment", _params, socket) do
    socket = update(socket, :count, &(&1 + 1))
    {:noreply, LiveStash.stash(socket)}
  end
end
```

See the `DurableStash` moduledoc for setup (adapter registration, backend
config, the `ensure_session_id` plug) and all options (`:vsn`, `:migrate`,
`:secret`, per-key scopes).

## How it works

- A plug puts a random `"sid"` into the cookie session; the adapter hashes it
  (with a secret) into the storage key of one `DurableStash.Session` process.
- All LiveViews of a session write through that single actor: per-key diffs,
  key-wise merge, per-key last-write-wins. Two tabs writing different keys
  cannot clobber each other; same-key writes are totally ordered.
- Every accepted write syncs to object storage immediately, so a deploy can
  never lose acknowledged state.
- Values are JSON-normalized at stash time — what you recover in dev is
  exactly what you would recover after a redeploy in prod.
- Each key declares a recovery scope: `:session` keys (the default) come back
  on every mount; `:reconnect` keys come back only when the client rejoins
  (crash, Wi-Fi drop, deploy) and clear on fresh navigation — for form
  drafts that should survive a redeploy mid-edit but start blank on "new
  thing".

`DurableStash.TestBackend` ships with the package: a faithful in-memory
`DurableServer.StorageBackend` (including etag CAS) for tests and `make run`
style development without S3 credentials.

## Installation

Not yet on Hex; consume as a path or git dependency:

```elixir
def deps do
  [
    {:durable_stash, path: "../durable_stash"}
  ]
end
```

## Credits

DurableStash stands on two lineages:

- the adapter API of **[LiveStash](https://github.com/software-mansion-labs/live-stash)**
  by Software Mansion (Apache-2.0)
- the durable-process runtime of **[DurableServer](https://github.com/phoenixframework/durable_server)**
  by Chris McCord (MIT)
