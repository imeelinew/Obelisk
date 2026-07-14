# Obelisk sync server

This directory contains the complete server-side sync stack for Obelisk 1.9:

- PostgreSQL is the source of truth.
- PowerSync publishes account-scoped rows to the offline SQLite databases on Apple devices.
- `obelisk-api` owns authentication and all client writes.

PowerSync never receives the API database password. Its source role has replication and read-only access; its bucket storage uses a separate database and role.

## Local stack

Requirements: Docker with Compose and OpenSSL.

```sh
cd Server
cp .env.example .env
./scripts/generate-jwt-key.sh
docker compose up --build
```

Replace every placeholder in `.env` first. Database passwords must be URL-safe because Compose places them in PostgreSQL connection URIs.

Local endpoints:

- API: `http://127.0.0.1:8081`
- PowerSync: `http://127.0.0.1:8080`
- PostgreSQL: `127.0.0.1:5432`

The API applies the one canonical schema on first start. The schema creates the required `powersync` logical publication for `collections`, `bookmarks`, and `usage_events` only.

## Authentication

Obelisk has no public registration endpoint. Provision the private owner account from the API container, passing the password on standard input:

```sh
printf '%s\n' 'a-long-private-password' | docker compose exec -T api /obelisk-api create-account owner@example.com
```

Login uses that email, password, and a persistent per-installation UUID. Passwords are stored with Argon2id. API access tokens last 15 minutes; refresh tokens are random, hashed in PostgreSQL, rotated on every use, and last 30 days. PowerSync tokens are separate one-hour JWTs with audience `powersync`.

The JWT private key is never committed. PowerSync verifies tokens through the API's public JWKS endpoint.

On a native Linux Docker host, the API runs as the distroless non-root user `65532`. Keep the private key owner-readable only and assign it to that user before starting the stack:

```sh
sudo chown 65532:65532 secrets/jwt-private.pem
sudo chmod 600 secrets/jwt-private.pem
```

## Production contract

Expose the API and PowerSync through HTTPS, then set `OBELISK_TOKEN_ISSUER` to the exact public API origin. Put those same origins in the macOS release as `ObeliskAPIURL` and `ObeliskPowerSyncURL`. The stack intentionally has no default production domain and accepts only administrator-provisioned accounts.

PowerSync anonymous telemetry sharing is disabled explicitly in `powersync/service.yaml`.

The personal production deployment uses the named Cloudflare Tunnel in `cloudflared/config.yml`:

- `https://api.elinew.tech` routes to the API container.
- `https://sync.elinew.tech` routes to the PowerSync container.

The tunnel credential JSON is never committed. Place it in `Server/cloudflared/`, assign it to the cloudflared non-root user, and start the production stack with both Compose files:

```sh
sudo chown -R 65532:65532 cloudflared
sudo chmod 700 cloudflared
sudo chmod 600 cloudflared/*.json cloudflared/config.yml
docker compose -f docker-compose.yml -f docker-compose.production.yml up -d --build
```
