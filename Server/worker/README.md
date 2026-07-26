# Obelisk Sync Worker

Cloudflare Workers + D1 backend for Obelisk synchronization. One private
deployment per user; devices authenticate with a single bearer access key.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/healthz` | Health check, no auth |
| `POST` | `/v1/push` | Upload full row state; per-row HLC field merge |
| `GET` | `/v1/changes?since=N` | Incremental download with cursor paging |
| `PUT` | `/v1/browser-history` | Device-scoped full-set reconcile |

Every push row is handled independently: an invalid row is rejected in the
response but never blocks other rows. Replaying any request is idempotent.

## One-time deployment

```sh
cd Server/worker
npm install

# 1. Log in to Cloudflare (free plan is enough)
npx wrangler login

# 2. Create the D1 database, then paste the returned database_id
#    into wrangler.jsonc
npx wrangler d1 create obelisk-sync

# 3. Apply the schema
npx wrangler d1 migrations apply obelisk-sync --remote

# 4. Set the access key (generate one, e.g. `openssl rand -base64 32`)
npx wrangler secret put SYNC_ACCESS_KEY

# 5. Deploy
npx wrangler deploy
```

The deploy output prints the Worker URL, e.g.
`https://obelisk-sync.<account>.workers.dev`. Enter that URL and the access
key in Obelisk 设置 → 云同步.

## Development

```sh
npm test              # vitest against a real D1 (miniflare)
npm run typecheck
npx wrangler dev      # local server on http://localhost:8787
```

Local dev needs `.dev.vars` with `SYNC_ACCESS_KEY=<key>`.
