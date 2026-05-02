# UniBookmark — Agent Notes

macOS Tahoe (26) menu-bar bookmark manager. Personal use, ad-hoc signed.

## Layout

```
Package.swift                    # 1 product: UniBookmarkMenu (executable)
Sources/UniBookmarkCore/         # Model + storage; no AppKit
  BookmarkStore.swift            # bookmarks.json CRUD, flock, normalizedURL
  UsageStore.swift               # usage.json CRUD, frecency scoring
Sources/UniBookmarkMenu/         # Menu bar app + SwiftUI manage window
  main.swift                     # AppDelegate, NSStatusItem menu, BookmarkFileWatcher, FaviconLoader
  BookmarksModel.swift           # @Observable; SINGLE source of truth for groupings
  BookmarkManagerView.swift      # SwiftUI manage window + add/edit sheet
  BookmarkManagerWindowController.swift
  PageMetadataFetcher.swift      # auto-fill title from <title>
scripts/
  build-app.sh                   # release build → .app + zip + ad-hoc sign
  make-icon.swift                # generates AppIcon.icns at build time
```

## Runtime data (NOT in repo)

Root: `$UNIBOOKMARK_HOME` or `~/Documents/UniBookmark/`

| File                          | Owner            | Purpose |
|-------------------------------|------------------|---------|
| `bookmarks.json`              | `BookmarkStore`  | Source of truth for bookmarks |
| `usage.json`                  | `UsageStore`     | `{ uuid: { count, lastClickedAt } }` keyed by UUID string |
| `favicons/<sha8>.png`         | `FaviconLoader`  | Per-host icon, 16×16 expected |
| `favicons/index.json`         | `FaviconLoader`  | `{ <sha8>: { fetchedAt, success } }` for TTL + negative cache |

`bookmarks.json` schema: `{ version: 1, bookmarks: [{ id, title, url, createdAt }] }`. `createdAt` may be missing in legacy files — `Bookmark.init(from:)` falls back to `.distantPast` so those bookmarks are excluded from "recently added".

## Invariants (non-obvious; do not break)

- **Single source of truth for groupings**: `BookmarksModel` computes `frequent` / `recent` / `others`. Both `AppDelegate.rebuildMenu()` and `BookmarkManagerView` read from these properties. Do not recompute groups elsewhere.
- **Usage recording is intent-based**: `model.openBookmark(_)` records to `usage.json`. Only the **menubar** click action calls it. The manage window's "在浏览器中打开" calls `NSWorkspace.shared.open` directly to avoid polluting frecency. Adding a tracked-open path from the manage window is a regression.
- **`onChange` callback on the model** drives menubar rebuilds. `reload()` and `openBookmark` fire it. Do not call `rebuildMenu()` inline from elsewhere — go through the model.
- **`BookmarkStore.add` / `update` / `delete`** wrap the read-modify-write under POSIX `flock` on `<root>/.lock` so a hypothetical second writer can't lose updates.
- **`BookmarkFileWatcher.start()`** must dispatch `openSources()` async after `stop()` — fd numbers can be recycled, and cancel handlers run on the main queue after the current call returns. Synchronous reopen reintroduces an fd-number race.
- **`FaviconLoader` is shared**: same instance used by menubar and `BookmarkManagerView`. Reading `loader.version` in a SwiftUI body subscribes the row to "new favicon arrived" events.
- **Manage-window "全部" deduplicates** (excludes IDs already in `frequent`/`recent`) because `List(selection:)` collides on duplicate IDs. **Menubar "全部" intentionally shows all bookmarks** — `NSMenuItem` has no selection model and a flat full list aids quick scanning.
- **`installMainMenu()`** is required: `LSUIElement=true` apps get no main menu, so `⌘C/⌘V/⌘X/⌘A/⌘Z` won't dispatch to focused `TextField`s without an Edit menu.
- **Activation policy toggling**: `.accessory` at launch and on manage-window close, `.regular` when the manage window opens, so the dock icon only appears while the window is up.
- **Window title/subtitle**: set via SwiftUI `.navigationTitle` / `.navigationSubtitle`. Setting `NSWindow.title`/`subtitle` directly is overwritten by the SwiftUI `NSHostingController`.
- **Liquid Glass** styling appears only when **built with the Xcode 26 SDK**. CLT/Xcode 16 produces a Sonoma-looking app. Code is identical; the SDK is the switch.
- **`NSImage` returned from `FaviconLoader.image(for:)`** is `.copy()`-ed before resizing — the underlying instance may be cached and shared by AppKit.
- **`URLComponents` `cacheKey`** is `SHA256(host[:port]).prefix(8)` hex — collisions across `host`s with similar punctuation were the reason for switching from string-replace to hash.

## Frecency

```
score = count * 0.95 ^ daysSinceLastClick
```

- `frequent`: top 5 by score, requires `count ≥ 3`
- `recent`: top 5 by `createdAt` desc, **excluding** anything already in `frequent`
- `others`: everything else (manage-window only)
- `usage.json` is best-effort; failures don't propagate

## Add-bookmark flow (Wave 1, current)

`BookmarkEditor` in `.add` mode:
1. `onAppear`: read `NSPasteboard.general`; if a valid http(s) URL, prefill the URL field.
2. URL field `onChange` → 500 ms debounce → `PageMetadataFetcher.title(for:)` → set title **only if** user hasn't typed in it.
3. `titleEditedByUser` flag distinguishes user typing from programmatic assignment (gated by `isProgrammaticTitleUpdate`).
4. `BookmarkEditor` in `.edit` mode marks `titleEditedByUser = true` to suppress fetching.

## Build / dist

`scripts/build-app.sh` → `.build/dist/UniBookmark.app` + `UniBookmark-<v>.zip`.
- Tries `--arch arm64 x86_64`; falls back to host arch if only CLT is installed.
- Runs `scripts/make-icon.swift` to render `AppIcon.icns` (white `bookmark.fill` over a yellow gradient, 22% rounded square).
- `codesign --force --deep --sign -` (ad-hoc). For distribution beyond this machine you'd need a Developer ID + notarization.
- Installed location: `/Applications/UniBookmark.app`. `touch` the bundle after copy to bust Dock icon cache.

## Roadmap (waves)

| Wave | Status | Scope |
|------|--------|-------|
| 1    | DONE   | Clipboard URL prefill + auto-fetch `<title>`; sectioned manage window; usage recorded only via menubar |
| 2    | TODO   | `.searchable` filter in manage window |
| 3    | TODO   | `Bookmark.pinned` flag + pinned section above 常用; back-compat decoder |
| 4    | TODO   | `CoreSpotlight` indexing; `application(_:continue:)` to open from Spotlight |
| 5    | TODO   | Carbon global hotkey (⌘⇧B) + AppleScript current-tab fetch from frontmost browser; needs `NSAppleEventsUsageDescription` |

## Identity

- Bundle ID: `local.elidev.UniBookmark`
- Min macOS: 14.0 (deployment), but Liquid Glass requires running on macOS 26
- `LSUIElement=true`
