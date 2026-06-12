# Changelog

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
