# UniBookmark

macOS menu-bar bookmark manager. Single-user, single-process,
file-backed, no network sync.

## Identity

- Bundle ID: `local.elidev.UniBookmark`
- `LSUIElement = true`
- `Package.swift` deployment target: macOS 26
- Liquid Glass is treated as a system-provided baseline. Build with
  Xcode 26 / the macOS 26 SDK; older SDKs and older macOS releases are
  not supported on this branch.
- Bundle short version string is sourced from `$VERSION` in
  `scripts/build-app.sh` (default `1.2.0`).
- `User-Agent` header used by `FaviconLoader` and `PageMetadataFetcher`
  is `UniBookmark/1.0`.

## Targets

```
UniBookmarkCore         library    — pure data layer, no AppKit
UniBookmarkMenu         executable — app
UniBookmarkSmokeTests   executable — assertion-based test runner
```

`UniBookmarkSmokeTests` runs as `swift run UniBookmarkSmokeTests`. It
is the test entry point; there is no `XCTest` target. The smoke tests
exercise `BookmarkStore` and `Bookmark` Codable behavior only.

## Source map

```
Sources/UniBookmarkCore/
  BookmarkStore.swift         CRUD, normalizedURL, file lock, store seeding
  UsageStore.swift            usage.json read/write, frecency, recent, cleanup

Sources/UniBookmarkMenu/
  main.swift                  AppDelegate, NSStatusItem menu, BookmarkFileWatcher,
                              FaviconLoader, FaviconRecord, hotkey wiring,
                              CoreSpotlight continueUserActivity handler
  BookmarksModel.swift        @Observable single source of truth for
                              frequent/recent/others
  BookmarkManagerView.swift   SwiftUI list + add/edit sheet (BookmarkEditor)
  BookmarkManagerWindowController.swift
                              NSWindow lifecycle, NSHostingController plumbing
  PageMetadataFetcher.swift   <title> scrape + entity decoding
  SpotlightIndexer.swift      CoreSpotlight reindex/delete + UUID round-trip
  GlobalHotkey.swift          Carbon RegisterEventHotKey wrapper
  BrowserCurrentTab.swift     AppleScript dialects per browser bundle ID
  AddBookmarkRequest.swift    @Observable seq-bumped channel for prefill

Sources/UniBookmarkSmokeTests/
  main.swift                  duplicate URL, legacy createdAt,
                              title persistence, usage grouping
```

## macOS 26 UI baseline

This branch follows the structure of Apple's
`LandmarksBuildingAnAppWithLiquidGlass` sample as a constraint, not as
loose inspiration:

- Prefer system SwiftUI containers: `NavigationSplitView`, `NavigationStack`,
  `List(selection:)`, `Form`, `.searchable`, and `.toolbar`.
- Let toolbar items receive Liquid Glass from their toolbar context. Use
  `ToolbarSpacer(.flexible)` and `ToolbarSpacer(.fixed)` to create the
  same kind of grouping shown in the sample.
- Do **not** hand-draw glass buttons, circular toolbar backgrounds,
  gradients, hover fills, shadows, or custom materials for ordinary
  toolbar/list controls.
- Use explicit `glassEffect` only for truly custom floating controls,
  matching the sample's badge-style use case. The bookmark manager window
  currently has no such custom floating control.
- Keep the bookmark list on SwiftUI's native `List(selection:)` path so
  selection, scroll edge behavior, row backgrounds, and future system
  styling stay owned by SwiftUI rather than AppKit drawing code.
- Settings-style text entry must use `Form` rows with
  `TextField(text:prompt:label:)` / `SecureField(text:prompt:label:)`.
  Do not build these rows manually with `VStack`, wrap editable fields in
  `LabeledContent`, or force `.textFieldStyle(.roundedBorder)` unless a
  later Apple sample shows that exact pattern for macOS settings.

The app still has an AppKit shell because it is an `LSUIElement` menu-bar
app with an `NSStatusItem`, Carbon hotkey, and explicit settings window
lifecycle. The manage window content should remain as close as possible to
the system SwiftUI path above.

## External runtime data

Root directory: `$UNIBOOKMARK_HOME` if set and non-empty, else
`~/Documents/UniBookmark/`. Created on first read attempt.

### `bookmarks.json`

```
{
  "version": 1,
  "bookmarks": [
    {
      "id":             "<UUID>",
      "title":          "<string>",
      "url":            "<string>",
      "createdAt":      "<ISO-8601>",
      "titleOptimized": <bool>,
      "isHidden":       <bool>
    }
  ]
}
```

`createdAt` is absent in legacy files written before that field
existed. `Bookmark.init(from:)` falls back to `.distantPast`.
Bookmarks with `.distantPast` created-at are excluded from the
"recent" group via `UsageStore.recent`. Older files may still contain
the removed `pinned` key; decoding ignores it.

`isHidden` is absent in legacy files written before hidden bookmarks
existed. Decoding falls back to `false`. Hidden bookmarks stay in the
same file but are excluded from the menubar menu, frecency groups,
title optimization, and Spotlight indexing. They appear only in the
manage window's "隐藏书签" page when that page is enabled.

### `usage.json`

```
{
  "<UUID-as-string>": {
    "count":         <int>,
    "lastClickedAt": "<ISO-8601>"
  }
}
```

Keys are `UUID.uuidString`; `UsageStore.load` rejects entries with
keys that fail `UUID(uuidString:)`. Writes are best-effort: failures
are silently swallowed because usage data is non-critical.

### `favicons/`

- `<sha8>.png` — favicon for one host. `<sha8>` is the lower-case hex
  of the first 8 bytes of `SHA256(host[:port])`. The same key is used
  by `FaviconLoader` and `SpotlightIndexer` so a thumbnail change is
  picked up by Spotlight on the next reindex.
- `index.json`:
  ```
  {
    "<sha8>": {
      "fetchedAt": "<ISO-8601>",
      "success":   <bool>
    }
  }
  ```
  Drives positive TTL (30 days, refresh in background) and negative
  TTL (7 days, suppress retry).

### `.lock`

Empty file used as the `flock` target by `BookmarkStore.withFileLock`.

### CoreSpotlight index

Items live in the user's CoreSpotlight index under domain
`local.elidev.UniBookmark.bookmarks`. `uniqueIdentifier` is
`bookmark.id.uuidString`. `SpotlightIndexer.reindexAll` calls
`deleteAllSearchableItems()` (not by-domain) before reindexing, to
clean up orphan items from any prior domain or identifier scheme.
`SpotlightIndexer.deleteAll()` is the documented cleanup path.

## External integrations

### Carbon hotkey

`GlobalHotkey` uses `RegisterEventHotKey` from `Carbon.HIToolbox`. No
permission is required. The hotkey is hard-coded at the call site in
`AppDelegate.registerGlobalHotkey()`: `⌥B` adds a normal bookmark and
`⌥H` adds a hidden bookmark. The stored properties `hotKeyRef` and
`eventHandler` are
`nonisolated(unsafe)` so the nonisolated `deinit` can release them.
The C event handler hops to the main actor via `DispatchQueue.main.async`
before calling Swift code.

### AppleScript browser capture

`BrowserCurrentTab.fetch()` reads
`NSWorkspace.shared.frontmostApplication.bundleIdentifier`, picks an
AppleScript dialect, and runs it via `NSAppleScript`. Bundle IDs that
return a script source: Safari + Tech Preview, Chrome + Canary, Brave
(stable/beta/nightly), Edge (stable/beta/dev), Vivaldi, Arc, Dia,
Opera. Firefox returns nil (no scriptable tab API). Two-line return
format: `"<URL>\nlinefeed<TITLE>"`. Splitting uses `maxSplits: 1` to
preserve newlines inside titles.

`Info.plist` must contain `NSAppleEventsUsageDescription`. macOS shows
a per-target-app permission prompt on first call; denial returns nil
and the caller is expected to fall back. The build script writes this
Info.plist key.

### CoreSpotlight continueUserActivity

`AppDelegate.application(_:continue:restorationHandler:)` opens the
URL via `NSWorkspace.shared.open` directly. It does **not** route
through `BookmarksModel.openBookmark` so Spotlight launches do not
contribute to frecency. Activation policy is reset to `.accessory`
afterwards.

## Invariants

These are not derivable from the code on its own. Breaking any of
them is a regression.

1. **`BookmarksModel` is the single source of truth for groupings.**
   `frequent`, `recent`, `others` are computed in `recomputeGroups`.
   Both `AppDelegate.rebuildMenu` and `BookmarkManagerView` read them.
   Recomputing groups elsewhere is prohibited.

2. **Each bookmark appears in exactly one of frequent / recent / others.**
   `recomputeGroups` deduplicates visible bookmarks. Hidden bookmarks
   are intentionally excluded from these groups. `List(selection:
   Bookmark.ID?)` relies on this; menubar `NSMenu` rendering also
   relies on it now.

3. **Hidden bookmarks are side-listed, not separately stored.**
   `Bookmark.isHidden` is the only source of truth. `⌥H` creates a
   hidden bookmark by default; the editor sheet can move a bookmark in
   or out of the hidden set. Hidden bookmarks must not appear in the
   menubar, Spotlight index, frecency groups, or title optimization.

4. **Only menubar clicks count as usage.**
   `BookmarksModel.openBookmark(_:)` records to `usage.json`. The
   manage-window context-menu "在浏览器中打开" calls `NSWorkspace`
   directly. `application(_:continue:)` (Spotlight) likewise opens
   directly. The intent is: usage = "I navigated to this", not
   "I touched this row in a list".

5. **`onChange` is the only path that triggers menubar rebuilds.**
   Wired in `applicationDidFinishLaunching`:
   `bookmarksModel.onChange = { self.scheduleRebuild() }`. The file
   watcher and `openBookmark` and `reload` all fire `onChange`.
   Calling `rebuildMenu` directly outside the debounce path is
   prohibited.

6. **`BookmarkStore.add` / `update` / `delete` execute
   under `flock` on `<root>/.lock`.** Any new mutator must use
   `withFileLock`.

7. **`BookmarkFileWatcher.start()` opens new fds asynchronously after
   `stop()`.** Cancel handlers run on the main queue after the
   current call returns. fd numbers can be recycled. A synchronous
   reopen reintroduces an fd-number race (handler closes the new fd).
   `restartPending` coalesces re-entrant `start()` calls.

8. **`FaviconLoader` is one shared instance.** Created in
   `AppDelegate`, passed to `BookmarkManagerWindowController` and
   thence to `BookmarkManagerView`. Reading `loader.version` inside a
   SwiftUI view body subscribes that view to favicon-arrival events.

9. **`NSImage` returned from `FaviconLoader.image(for:)` is `.copy()`-ed
   before resizing.** AppKit may share the underlying instance.

10. **`installMainMenu()` is required.** `LSUIElement = true` apps get
   no main menu, so `⌘C/⌘V/⌘X/⌘A/⌘Z` will not dispatch to focused
   `TextField`s without a populated Edit menu in `NSApp.mainMenu`.

11. **Activation policy toggles between `.accessory` and `.regular`.**
    `.accessory` at launch, on manage-window close, and after
    Spotlight `application(_:continue:)`. `.regular` when the manage
    window is shown. The dock icon is intentionally ephemeral.

12. **Window title and subtitle are set via SwiftUI
    `.navigationTitle` / `.navigationSubtitle`.** Setting
    `NSWindow.title` / `NSWindow.subtitle` directly is overwritten by
    `NSHostingController` synchronization.

13. **`URLComponents` cache key is `SHA256(host[:port]).prefix(8)` hex.**
    Earlier code used a naive non-alphanumeric → `-` substitution
    that collided across hosts. `FaviconLoader.cacheKey` and
    `SpotlightIndexer.faviconCacheKeys` must agree on this scheme.

14. **`BookmarkStoreError.errorDescription` is Chinese.** UI surfaces
    pull localized descriptions. English / mixed strings for these
    cases are a regression.

15. **Add/edit failures alert on the editor sheet, not the parent
    view.** `BookmarksModel.add` and `update` return `String?`
    (nil = success). `BookmarksModel.errorMessage` is reserved for
    load-time errors and other parent-level concerns. Routing add /
    update errors through `errorMessage` queues the alert behind the
    sheet, so it only appears after the user dismisses the sheet.

16. **`PageMetadataFetcher` does not use `NSAttributedString(html:)`.**
    That API loads WebKit on the main thread. Use the regex +
    explicit entity decoding path.

17. **`AddBookmarkRequest.seq` is consumed in both `.onAppear` and
    `.onChange`.** `.onChange` does not fire for the value present at
    mount time; `.onAppear` covers the cold-launch hotkey path where
    the request is bumped before the view exists.

18. **The app icon has a single source artwork.**
    Replace `Sources/UniBookmarkMenu/Resources/AppIcon.png` when the
    artwork changes; `scripts/make-icon.swift` derives the `.icns`
    renditions from that PNG during app packaging.

## Frecency

```
score(b) = b.usage.count * 0.95 ^ daysSinceLastClick
```

Implemented in `UsageStore.topFrequent`. `pow(0.95, days)` with
`days = max(0, …)` clamps future-dated stamps to no boost.

- `frequent`: top 5 by score, `count >= 3`.
- `recent`: top 5 by `createdAt` desc, excluding bookmarks already
  in `frequent`. Bookmarks with `createdAt == .distantPast` are
  filtered out.
- `others`: everything not in frequent/recent.
- Group cap (`5`) is the `groupSize` parameter on `BookmarksModel`
  and is held private; UI does not currently expose it.

## Build and signing

`scripts/build-app.sh`:

- Attempts `swift build --arch arm64 --arch x86_64`. Falls back to
  host arch if the multi-arch build fails (Command Line Tools
  installation cannot produce universal binaries; only a full Xcode
  installation can).
- Strips debug symbols from the binary.
- Generates `Resources/AppIcon.icns` by running
  `scripts/make-icon.swift`. The icon source is the shared
  `Sources/UniBookmarkMenu/Resources/AppIcon.png` artwork.
- Writes `Info.plist`. Required keys:
  `LSUIElement`, `LSMinimumSystemVersion=26.0`,
  `NSUserActivityTypes=[com.apple.corespotlightitem]`,
  `NSAppleEventsUsageDescription`,
  `CFBundleIconFile=AppIcon`.
- Signs ad-hoc (`codesign --force --deep --sign -`). The bundle is
  not Developer-ID signed; running it on another Mac requires the
  user to override Gatekeeper manually.
- Outputs `.build/dist/UniBookmark.app` and
  `.build/dist/UniBookmark-<VERSION>.zip`.

## Tests

`swift run UniBookmarkSmokeTests` exercises:

- `BookmarkStore.add` rejects URLs whose normalized form already
  exists (covers default-port and trailing-slash equivalence).
- Legacy `bookmarks.json` without `createdAt` decodes with
  `.distantPast`.
- `UsageStore.topFrequent` minimum-count gating and `recent`
  dedup filtering.

There is no UI test coverage. Manual scenarios that have surfaced
historical regressions:

- Cold-launch global hotkey (manage window not yet open) — must
  open the add sheet, not just the manage list. Covered by
  invariant 17.
- Spotlight badge transparency around the app icon — covered by
  invariant 18.
- Duplicate-URL alert ordering during add — covered by
  invariant 15.
- fd race when `bookmarks.json` is replaced repeatedly — covered
  by invariant 6.

## Known limitations

- The hotkey is hard-coded. There is no UI to rebind it.
- Firefox is not supported for browser tab capture.
- The data root is not synchronized; placing the root inside
  iCloud Drive (`UNIBOOKMARK_HOME`) is the supported sync
  mechanism and is not enforced or detected by the app.
- Universal binaries require a full Xcode installation; the build
  script transparently falls back to the host arch otherwise.
- The bundle is ad-hoc signed only; redistribution to other
  machines is out of scope.
