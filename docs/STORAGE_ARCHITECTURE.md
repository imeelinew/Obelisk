# Obelisk Storage & Synchronization Architecture

This document is the canonical specification for how Obelisk stores data
locally and synchronizes it across devices.

## Overview

- **Local store**: one SQLite database per device (GRDB), the source of truth
  for every UI. All writes are local-first and work offline.
- **Backend**: a Cloudflare Worker with a D1 (SQLite) database
  (`Server/worker/`). One private deployment per user, free tier.
- **Authentication**: a single bearer access key, generated at deployment,
  stored in the macOS Keychain. There are no accounts, tokens, or sessions.
- **Protocol**: state-based push/pull over HTTPS. No CRUD operation queue is
  ever replayed against the server; clients upload the *current state* of
  changed rows and the server merges them field-by-field.

## Domain tables

Identical shape on the client, D1, and the wire (snake_case columns):

| Table | Kind | Conflict model |
| --- | --- | --- |
| `bookmarks` | versioned | per-field HLC merge, soft delete (`deleted_at`) |
| `collections` | versioned | per-field HLC merge, soft delete |
| `browser_history_settings` | versioned | per-field HLC merge (singleton row) |
| `usage_events` | append-only | insert-once by id, immutable |
| `browser_history_events` | device-scoped mirror | full-set replace per source device |

Versioned tables carry `field_versions`: a JSON map from column name to a
hybrid logical clock timestamp `{milliseconds, counter, deviceID}`. A field
value is replaced only by a strictly newer timestamp (ties broken by device
ID), so replays and full re-pushes are idempotent and clock skew cannot
resurrect old data.

## Client (ObeliskData / ObeliskSync)

- Every domain write runs in one SQLite transaction that also upserts an
  entry into `outbox (table_name, row_id, queued_at, attempts, last_error)`.
  Rewriting a row refreshes `queued_at`, coalescing repeated edits.
- Browser history is not tracked per row: local reconciliation marks a single
  `browser_history/local-device` outbox entry, and the engine uploads the
  device's complete current set to the reconcile endpoint.
- `sync_state` holds the HLC clock and the pull cursor.
- The sync engine (`CloudSyncController` + `SyncEngine`) performs serialized
  passes: **push** (read outbox → upload full row state → delete entries whose
  `queued_at` is unchanged) then **pull** (`/v1/changes?since=cursor`, apply
  pages with the same HLC merge, advance the cursor). Remote applies never
  re-enter the outbox.
- A row rejected by the server records `attempts`/`last_error` on its outbox
  entry and is skipped after 5 attempts. **One bad row never blocks the
  queue.**
- Triggers: outbox growth (debounced by the observation), a 30-second timer,
  app activation, and network-path recovery. All funnel into a single
  serialized sync task.
- First contact with a server (cursor 0) enqueues a full push of every local
  row; combined with a full pull, both sides converge deterministically.

## Server (Cloudflare Worker + D1)

- `POST /v1/push`: up to 500 rows. Each row is validated and merged
  independently; the response lists per-row `applied`/`rejected` results.
  Writes allocate a global sequence number (`sync_meta.seq`) in the same
  atomic batch as the row write, so cursors never miss data.
- `GET /v1/changes?since=N`: returns rows with `seq > N` from every table
  (1000 per table per page) plus browser-history tombstones, with `cursor`
  and `hasMore` for paging. Rows may be re-sent across pages; clients apply
  idempotently.
- `PUT /v1/browser-history`: replaces the row set for one source device.
  Deleted rows get tombstones (45-day retention) so other devices drop their
  mirrors; rows older than the 30-day retention window are pruned without
  tombstones because every client filters by the same cutoff.
- Concurrency: D1 serializes batches; read-merge-write races are guarded by
  compare-and-swap on `field_versions` with bounded retries.

## Invariants

- Hidden, archived, or deleted bookmarks cannot stay pinned. The rule is
  enforced identically on the client and the server after every merge, so all
  replicas converge regardless of arrival order.
- `usage_events` are immutable and deduplicated by id.
- Deletion of bookmarks and collections is a soft delete via `deleted_at`;
  snapshots filter deleted rows.
- Cloud sync is optional. Disabling it stops the engine; local writes keep
  accumulating in the outbox and upload when sync is re-enabled.

## Legacy migration

Databases written by the retired PowerSync stack (`ps_data__*` JSON tables,
views, triggers, and the `ps_crud` queue) are migrated on first open: domain
rows are copied into plain tables, every `ps_*` object is dropped, and the
old mutation queue is discarded — the state-based protocol re-uploads current
rows on the next full push, so nothing is lost.
