# Obelisk

Obelisk is a macOS-only bookmark application. Prefer native Apple controls and macOS conventions.

## Code ownership

- `Obelisk/`: macOS UI and system integrations
- `Packages/ObeliskKit/Sources/ObeliskCore`: domain models and deterministic business rules
- `Packages/ObeliskKit/Sources/ObeliskData`: SQLite schema, queries, and local transactions
- `Packages/ObeliskKit/Sources/ObeliskSync`: authentication, sessions, and PowerSync integration
- `Server/worker/`: Cloudflare Worker sync backend

Keep domain, data, and sync logic in the package. AppKit and UIKit do not belong in `ObeliskKit`. UI code accesses storage and sync through the package, without issuing SQL, calling sync endpoints, or accessing the access key directly.

## Product constraints

- Browser-history collection and the global quick-search panel were removed. Preserve ordinary bookmark search and quick-add shortcuts.
- User-facing copy has no sentence-ending periods. Use full-width Chinese commas (`，`), never ASCII commas.
- Cloud sync is optional. All writes work offline and while sync is disabled.
- Keychain stores the sync access key and explicit secrets only. Do not introduce application-level database encryption or database keys.

## Storage and synchronization

For storage or sync changes, consult `docs/STORAGE_ARCHITECTURE.md`, the canonical specification. Preserve these invariants:

- SQLite is the local source for every UI. Writes are local-first, with one domain model and one canonical schema shared by macOS and the Worker's D1 database. No parallel persistence path.
- Sync uploads full row state from the outbox and merges per-field HLC versions. Preserve field-version conflict rules, soft deletes, immutable usage events, and idempotent requests. Do not replace state-based sync with operation replay; a bad row must not block other uploads.
- With sync enabled, every local create, update, delete, and usage write begins uploading immediately. Active devices converge automatically without manual sync.
- Re-enabling sync uploads queued local changes and converges with remote state. Foreground activation and network recovery resume sync automatically.

## macOS windows

Obelisk is a regular Dock application (`LSUIElement = false`). The menu bar item is a secondary entry point.

Let AppKit manage activation, Dock reopen events, Spaces, hiding, minimizing, and window ordering. Do not override `applicationShouldHandleReopen`, defer Dock activation through queues or tasks, force windows onto the active Space, or use unconditional frontmost ordering.

Create the primary window through the standard untitled-window delegate path when none exists. Explicit window requests may use ordinary `makeKeyAndOrderFront` and application activation APIs. Introduce custom lifecycle behavior only for a reproducible failure verified against native AppKit behavior.

## Implementation choices

- Keep the implementation current. Remove obsolete code, legacy formats, compatibility shims, old migrations, and speculative fallbacks in the affected scope unless explicitly requested otherwise.
- Prefer focused types with clear ownership. Validate at trust boundaries: user input, network responses, and database constraints.
- Follow Swift 6 concurrency: main-actor UI state, structured concurrency, and safely transferable cross-actor values.
- Use platform SDKs and existing dependencies when they provide the needed capability.
- Keep credentials, tokens, signing material, local databases, generated apps, archives, and server runtime data out of commits.

## Completion and verification

Carry the requested change through implementation and relevant verification. Fix failures caused by the change and rerun the affected check without asking for approval at each step. Finish when the requested behavior is implemented and applicable checks pass, or report a concrete blocker.

This repository has no test targets or test source files. Do not add, restore, or run tests. Use builds and static checks:

- After macOS UI or shared-package changes:

  ```sh
  xcodebuild -project Obelisk.xcodeproj -scheme Obelisk -configuration Debug -destination 'platform=macOS' build
  ```

- After Worker endpoint, D1 schema, or merge-behavior changes:

  ```sh
  (cd Server/worker && npm run typecheck)
  ```

Documentation-only changes do not require either command. Review the complete diff for the requested change and remove dead code and temporary artifacts introduced by it. Report what changed, exactly which checks ran, and any remaining blocker.
