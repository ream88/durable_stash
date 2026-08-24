# Changelog

## 0.1.2 (2026-08-24)

- Recovery no longer starts a session when nothing is in scope to recover. A
  view whose keys are all `:reconnect` had no recoverable state on a fresh or
  disconnected mount, but still read the stored object and wrote one back —
  so every crawler request to a public form left a stash in the bucket, and
  the read sat in the HTTP render path. Such a mount now returns `:not_found`
  without touching the store.
- The `req` version is no longer forced on your application. `req` was
  declared here only to hold the tree above a CVE, which a package may not do
  — Hex refuses to build one that overrides a dependency, and `lib/` never
  called `Req` in the first place. `req_s3` now accepts `req` 0.6 and 0.7, so
  the pin it worked around is gone.

## 0.1.1 (2026-06-22)

- Writes no longer block the calling LiveView on the object-store PUT. Each
  stash merged in memory and then ran the S3 round-trip *inside* the
  `handle_call`, so under `auto_stash: true` every keystroke paid the network
  latency and the writing view felt sluggish. Writes now reply first and flush
  in a `handle_continue/2`, keeping the LiveView off the round-trip while still
  persisting each write.

## 0.1.0 (2026-06-12)

Initial release.

- `DurableStash` — a [LiveStash](https://hex.pm/packages/live_stash) adapter
  backed by [DurableServer](https://hex.pm/packages/durable_server): one
  durable process per browser session, persisted to S3-compatible object
  storage. State survives live navigation, reconnects, LiveView crashes, and
  redeploys; recovery happens on every mount.
- Per-key diff writes with key-wise merge — concurrent tabs writing different
  keys cannot clobber each other.
- Per-key recovery scopes: `:session` (recover on every mount) and
  `:reconnect` (recover only on rejoins — crashes, Wi-Fi drops, deploys —
  and clear on fresh navigation; right for form drafts).
- `vsn`/`migrate` options for versioning the stored shape; mismatches without
  a migration discard to defaults.
- JSON-safety guards (`on_invalid_value: :raise | :log`) and JSON
  normalization at stash time, so recovered values are identical in dev and
  prod.
- `DurableStash.TestBackend` — an in-memory `DurableServer.StorageBackend`
  with faithful etag CAS, for tests and local development without S3.
