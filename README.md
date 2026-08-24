# DurableStash

Keep Phoenix LiveView state alive across reconnects, crashes, and redeploys.

A LiveView's assigns live in memory and vanish when the socket drops, the
process crashes, or you deploy. DurableStash saves the assigns you pick to
object storage and restores them the next time the LiveView mounts. The saved
copy belongs to the browser session, so every LiveView the user opens shares
it. Under the hood it plugs into
[LiveStash](https://github.com/software-mansion-labs/live-stash) and stores
state through [DurableServer](https://hex.pm/packages/durable_server).

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

    socket =
      if connected?(socket) do
        {_status, socket} = LiveStash.recover_state(socket)
        socket
      else
        socket
      end

    {:ok, socket}
  end

  def handle_event("increment", _params, socket) do
    socket = update(socket, :count, &(&1 + 1))
    {:noreply, LiveStash.stash(socket)}
  end
end
```

`mount/3` runs twice — once for the HTTP render, once when the socket
connects — and recovery on the HTTP render costs an object-store round-trip.
A view with only `:reconnect` keys skips it, since nothing is recoverable
without a socket. A view with `:session` keys pays it so the stored value
makes the first paint; guard the call with `connected?/1` if you would rather
it did not. See the `DurableStash` moduledoc.

## Scopes

Not all state wants the same recovery policy, so each stored key declares one:

```elixir
use LiveStash, adapter: DurableStash,
  stored_keys: [
    theme: :session,    # recover on every mount (the default for bare atoms)
    draft: :reconnect   # recover only on rejoins; cleared on fresh navigation
  ]
```

- `:session` — recovered on every mount: live navigation, reconnects, crashes,
  redeploys. Right for settings the user expects to stick.
- `:reconnect` — recovered only when the client *rejoins* an existing view
  (`_mounts > 0`): Wi-Fi drops, LiveView crashes, and redeploys — the browser
  stays on the page through all of these. A fresh navigation to the view
  clears the stored values, so starting a new thing starts blank. Right for
  in-progress form drafts.

See the `DurableStash` moduledoc for setup (adapter registration, backend
config, the `ensure_session_id` plug) and all options (`:vsn`, `:migrate`,
`:secret`).

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

`DurableStash.TestBackend` ships with the package: a faithful in-memory
`DurableServer.StorageBackend` (including etag CAS) for tests and `make run`
style development without S3 credentials.

## Installation

```elixir
def deps do
  [
    {:durable_stash, "~> 0.1.0"}
  ]
end
```

## Credits

DurableStash stands on two lineages:

- the adapter API of **[LiveStash](https://github.com/software-mansion-labs/live-stash)**
  by Software Mansion
- the durable-process runtime of **[DurableServer](https://github.com/phoenixframework/durable_server)**
  by Chris McCord
