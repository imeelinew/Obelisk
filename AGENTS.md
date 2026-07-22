# Obelisk Engineering Guide

## Project boundaries

- Keep the macOS and iOS applications in this repository as separate targets.
- Put platform-independent code in `Packages/ObeliskKit`:
  - `ObeliskCore`: domain models and deterministic business rules.
  - `ObeliskData`: SQLite schema, queries, and local transactions.
  - `ObeliskSync`: authentication, session handling, and PowerSync integration.
- Keep macOS UI and system integrations in `Obelisk/`.
- Keep iOS UI and system integrations in `Obelisk iOS/`.
- Keep backend code and deployment configuration in `Server/`.
- Never import AppKit or UIKit into `ObeliskKit`. Shared SwiftUI code is acceptable only when it is genuinely identical on both platforms.

## Product decisions

- Do not invent iOS features, navigation, interaction behavior, or visual design. Implement them only after the user has approved the relevant product decision.
- Prefer native Apple controls and platform conventions. Do not force the macOS layout onto iOS.
- A shared feature must have the same domain behavior on both platforms, even when its presentation differs.
- Do not change existing macOS behavior while implementing iOS unless the shared behavior itself must change.
- User-facing copy must not contain sentence-ending periods. Commas are allowed only as full-width Chinese commas (`，`), never ASCII commas.

## macOS window lifecycle

- Obelisk is a regular Dock application (`LSUIElement` is `false`). Keep the menu bar item as a secondary entry point; it must not replace or intercept normal Dock activation.
- Let AppKit manage application activation, Dock reopen events, Spaces, hiding, minimizing, and window ordering. Do not override `applicationShouldHandleReopen`, defer Dock activation through queues or tasks, force windows onto the active Space, or use unconditional frontmost ordering.
- Use the standard untitled-window delegate path to create the primary window when none exists. Showing an explicitly requested window may use ordinary `makeKeyAndOrderFront` and application activation APIs.
- Do not add speculative macOS window-lifecycle workarounds. Require a reproducible failure and verify the fix against native AppKit behavior before introducing custom lifecycle code.

## Storage and sync contract

- Follow `docs/STORAGE_ARCHITECTURE.md` as the canonical storage and synchronization specification.
- SQLite is the local source used by every UI. All writes are local-first and must work while offline or while cloud sync is disabled.
- UI code must not issue SQL, call sync endpoints, or access authentication secrets directly. Route those operations through `ObeliskData` and `ObeliskSync`.
- Maintain one domain model and one canonical schema across macOS, iOS, the API, and PostgreSQL. Do not add a parallel persistence path.
- Preserve the existing HLC field-version conflict rules, tombstone deletion model, immutable usage events, and idempotent mutation handling.
- Cloud sync remains optional. Re-enabling it must upload queued local changes and converge with remote state.
- When cloud sync is enabled, every local create, update, delete, and usage write must begin uploading immediately, and every active device must converge automatically without a manual sync action. Foreground activation and network recovery must resume or rebuild synchronization automatically.
- Keychain is for authentication sessions and explicit secrets only. Do not add application-level database encryption or database keys to Keychain.

## Change policy

- Keep the implementation direct and current. Do not retain obsolete code, legacy formats, compatibility shims, old migrations, or speculative fallbacks unless explicitly requested.
- Refactor shared logic instead of duplicating it between app targets.
- Prefer small, focused types and clear ownership over indirection or defensive scaffolding.
- Use Swift 6 concurrency rules: isolate UI state on the main actor, use structured concurrency, and make cross-actor values safely transferable.
- Validate data at real trust boundaries such as user input, network responses, and database constraints. Do not scatter redundant checks through internal code.
- Do not add a dependency when the platform SDK or an existing dependency already provides the required capability.
- Never commit credentials, tokens, signing material, local databases, generated apps, archives, or server runtime data.

## Verification

Test every completed step at the narrowest useful level, then run the affected target's build before handing it off.

```sh
swift test --package-path Packages/ObeliskKit
xcodebuild -project Obelisk.xcodeproj -scheme Obelisk -configuration Debug -destination 'platform=macOS' build
xcodebuild -project Obelisk.xcodeproj -scheme 'Obelisk iOS' -configuration Debug -destination 'generic/platform=iOS Simulator' build
(cd Server && go test ./...)
```

- Run shared package tests after changing domain, data, or sync code.
- Build both app targets after changing shared code.
- Run server tests after changing API, schema, authentication, or merge behavior.
- Add focused regression tests for every fixed bug and every non-trivial domain rule.
- Before finishing, review the complete diff, remove dead code and temporary artifacts, and report exactly what was tested.

## Cursor Cloud specific instructions

The cloud VM is Linux, so only the `Server/` Go stack can build and run here. The macOS and iOS Xcode targets and the `Packages/ObeliskKit` Swift package require macOS/Xcode and cannot be built or tested in this environment; skip their `swift test`/`xcodebuild` verification steps unless you are on an Apple host.

- Go 1.26 is required by `Server/go.mod` and is installed at `/usr/local/go` with `/usr/bin/go` symlinked to it. The default Ubuntu Go (1.22) is too old; if `go version` ever reports < 1.26, re-point `/usr/bin/go` to `/usr/local/go/bin/go`.
- Server build/vet/test: `cd Server && go build ./... && go vet ./... && go test ./...`. Unit tests need no database.
- Running the API for real (auth, schema, sync mutations) needs PostgreSQL. PostgreSQL 16 is installed but the cluster is not auto-started on a fresh VM: start it with `sudo pg_ctlcluster 16 main start`. Create the app role/db once with `CREATE ROLE obelisk_api LOGIN PASSWORD '...'; CREATE DATABASE obelisk OWNER obelisk_api;` (as the `postgres` user).
- The API applies its schema (and the `powersync` publication) automatically on `create-account` and on startup, so no manual migration step is needed against a fresh `obelisk` database.
- Required env vars to run `Server/cmd/obelisk-api` directly: `OBELISK_DATABASE_URL`, `OBELISK_TOKEN_ISSUER`, `OBELISK_JWT_KEY_ID`, `OBELISK_JWT_PRIVATE_KEY_PATH` (see `Server/internal/config/config.go`). Generate the JWT key with `Server/scripts/generate-jwt-key.sh` (writes to the gitignored `Server/secrets/`).
- There is no public registration: provision an account with `printf '%s\n' 'password' | ./obelisk-api create-account owner@example.com`, then log in via `POST /v1/auth/login` with `email`, `password`, and a UUID `deviceId`.
- The full documented stack (Postgres + api + PowerSync) in `Server/docker-compose.yml` needs Docker, which is not installed by default here. Running the api directly against local Postgres exercises the same auth and write paths without PowerSync; only add Docker if you specifically need to test PowerSync streaming.
