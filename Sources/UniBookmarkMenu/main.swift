import AppKit
import Carbon.HIToolbox
import CoreSpotlight
import CryptoKit
import Foundation
import Observation
import UniBookmarkCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let maxMenuTitlePixelWidth: CGFloat = 300
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = BookmarkStore()
    private let usageStore = UsageStore()
    private lazy var spotlightIndexer = SpotlightIndexer(rootDirectory: store.rootDirectory)
    private var bookmarkWatcher: BookmarkFileWatcher?
    private var rebuildDebounce: DispatchWorkItem?
    private lazy var bookmarksModel = BookmarksModel(
        store: store,
        usageStore: usageStore,
        spotlightIndexer: spotlightIndexer
    )
    private let addRequest = AddBookmarkRequest()
    private lazy var managerWindow = BookmarkManagerWindowController(
        model: bookmarksModel,
        faviconLoader: faviconLoader,
        addRequest: addRequest
    )
    private var globalHotkey: GlobalHotkey?
    private lazy var faviconLoader: FaviconLoader = {
        let loader = FaviconLoader(rootDirectory: store.rootDirectory)
        loader.onIconLoaded = { [weak self] in
            self?.scheduleRebuild()
        }
        return loader
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        configureStatusItem()
        bookmarksModel.onChange = { [weak self] in
            self?.scheduleRebuild()
        }
        startBookmarkWatcher()
        registerGlobalHotkey()
        rebuildMenu()
    }

    /// Wave 5: ⌥B from anywhere → fetch the frontmost browser's current
    /// tab via AppleScript and present the manage window's add sheet
    /// prefilled with URL + title. Falls back to clipboard URL prefill if
    /// the frontmost app isn't a recognized browser or automation
    /// permission was denied.
    ///
    /// Note: ⌥B normally types `∫` in text fields. Carbon's `RegisterEventHotKey`
    /// intercepts the keystroke at the system level so it never reaches the
    /// focused app — we get the press, the focused app does not.
    private func registerGlobalHotkey() {
        let hotkey = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(optionKey)
        )
        hotkey.onPress = { [weak self] in
            self?.handleGlobalHotkey()
        }
        globalHotkey = hotkey
    }

    private func handleGlobalHotkey() {
        let tab = BrowserCurrentTab.fetch()
        addRequest.request(url: tab?.url, title: tab?.title)
        NSApp.setActivationPolicy(.regular)
        managerWindow.show()
    }

    /// LSUIElement apps get no main menu by default, which means ⌘C/⌘V/⌘X/⌘A
    /// have nowhere to dispatch when a TextField is focused in our settings
    /// window. Install a minimal Edit menu that routes through the responder
    /// chain so standard text editing shortcuts work.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出 UniBookmark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "UniBookmark")
            button.title = ""
        }
    }

    private func startBookmarkWatcher() {
        bookmarkWatcher = BookmarkFileWatcher(fileURL: store.fileURL) { [weak self] in
            // model.reload fires onChange → menubar rebuild via the callback
            // wired in applicationDidFinishLaunching.
            self?.bookmarksModel.reload()
        }
    }

    private func scheduleRebuild() {
        rebuildDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildMenu()
        }
        rebuildDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    @objc private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if let error = bookmarksModel.loadErrorMessage {
            let errorItem = NSMenuItem(title: "读取失败: \(error)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        } else if bookmarksModel.bookmarks.isEmpty {
            let header = NSMenuItem(title: "书签", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(NSMenuItem.separator())
            let emptyItem = NSMenuItem(title: "暂无书签", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            let pinned = bookmarksModel.pinned
            let frequent = bookmarksModel.frequent
            let recent = bookmarksModel.recent
            // `model.others` is already deduped (excludes pinned/frequent/recent).
            // Showing the full list here was duplicating items in the
            // dropdown — match the manage window's "everything once" behavior.
            let others = bookmarksModel.others

            if !pinned.isEmpty {
                appendSection(title: "置顶", bookmarks: pinned, to: menu)
            }
            if !frequent.isEmpty {
                appendSection(title: "常用", bookmarks: frequent, to: menu)
            }
            if !recent.isEmpty {
                appendSection(title: "最近添加", bookmarks: recent, to: menu)
            }
            if !others.isEmpty {
                let needsHeader = !pinned.isEmpty || !frequent.isEmpty || !recent.isEmpty
                appendSection(title: needsHeader ? "全部" : "", bookmarks: others, to: menu)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let manageItem = NSMenuItem(title: "设置", action: #selector(openManager), keyEquivalent: "")
        menu.addItem(manageItem)
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func appendSection(title: String, bookmarks: [Bookmark], to menu: NSMenu) {
        if menu.items.last != nil {
            menu.addItem(NSMenuItem.separator())
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for bookmark in bookmarks {
            menu.addItem(menuItem(for: bookmark))
        }
    }

    private func menuItem(for bookmark: Bookmark) -> NSMenuItem {
        let item = NSMenuItem(
            title: truncatedTitle(bookmark.title),
            action: #selector(openBookmark(_:)),
            keyEquivalent: ""
        )
        item.representedObject = bookmark
        item.toolTip = "\(bookmark.title)\n\(bookmark.url)"
        item.image = faviconLoader.image(for: bookmark.url)
        return item
    }

    private func truncatedTitle(_ title: String) -> String {
        let ellipsis = "…"
        let font = NSFont.menuFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        guard title.size(withAttributes: attributes).width > maxMenuTitlePixelWidth else {
            return title
        }

        var low = title.startIndex
        var high = title.endIndex
        var best = ""

        while low < high {
            let distance = title.distance(from: low, to: high)
            let mid = title.index(low, offsetBy: distance / 2)
            let candidate = String(title[..<mid]).trimmingCharacters(in: .whitespacesAndNewlines) + ellipsis

            if candidate.size(withAttributes: attributes).width <= maxMenuTitlePixelWidth {
                best = candidate
                if mid == title.endIndex { break }
                low = title.index(after: mid)
            } else {
                if mid == low { break }
                high = mid
            }
        }

        return best.isEmpty ? ellipsis : best
    }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let bookmark = sender.representedObject as? Bookmark else { return }
        bookmarksModel.openBookmark(bookmark)
    }

    @objc private func openManager() {
        NSApp.setActivationPolicy(.regular)
        managerWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard
            userActivity.activityType == CSSearchableItemActionType,
            let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
            let id = spotlightIndexer.bookmarkID(for: identifier)
        else {
            return false
        }

        bookmarksModel.reload()
        guard let bookmark = bookmarksModel.bookmarks.first(where: { $0.id == id }) else {
            return false
        }
        if let url = URL(string: bookmark.url) {
            NSWorkspace.shared.open(url)
        }
        restorationHandler([])
        NSApp.setActivationPolicy(.accessory)
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

private struct FaviconRecord: Codable {
    var fetchedAt: Date
    var success: Bool
}

@MainActor
@Observable
final class FaviconLoader {
    @ObservationIgnored var onIconLoaded: (() -> Void)?
    /// Bumped whenever a new favicon lands on disk. Views that read this
    /// in their body get re-rendered so cached lookups pick up new icons.
    private(set) var version: Int = 0

    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private let indexURL: URL
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var index: [String: FaviconRecord] = [:]
    @ObservationIgnored private let session: URLSession

    /// Cached icons older than this are refreshed in the background.
    @ObservationIgnored private let positiveTTL: TimeInterval = 30 * 24 * 3600
    /// Failed lookups are not retried for this long.
    @ObservationIgnored private let negativeTTL: TimeInterval = 7 * 24 * 3600

    init(rootDirectory: URL) {
        self.cacheDirectory = rootDirectory.appendingPathComponent("favicons", isDirectory: true)
        self.indexURL = cacheDirectory.appendingPathComponent("index.json")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpAdditionalHeaders = [
            "User-Agent": "UniBookmark/1.0"
        ]
        self.session = URLSession(configuration: configuration)
        loadIndex()
    }

    func image(for urlString: String) -> NSImage? {
        guard
            let pageURL = URL(string: urlString),
            let key = cacheKey(for: pageURL)
        else {
            return nil
        }

        let fileURL = cacheDirectory.appendingPathComponent("\(key).png")
        let record = index[key]
        let now = Date()

        if let image = NSImage(contentsOf: fileURL) {
            // Copy before mutating size; the underlying NSImage may be cached
            // and shared, and changing size on a shared instance can affect
            // unrelated rendering elsewhere.
            let copy = image.copy() as? NSImage ?? image
            copy.size = NSSize(width: 16, height: 16)

            // Refresh stale icons in the background — keep showing the cached one.
            if let record, now.timeIntervalSince(record.fetchedAt) > positiveTTL {
                fetchIfNeeded(pageURL: pageURL, key: key, fileURL: fileURL)
            }
            return copy
        }

        // Negative cache: don't hammer sites that recently failed.
        if let record, !record.success, now.timeIntervalSince(record.fetchedAt) < negativeTTL {
            return nil
        }

        fetchIfNeeded(pageURL: pageURL, key: key, fileURL: fileURL)
        return nil
    }

    private func fetchIfNeeded(pageURL: URL, key: String, fileURL: URL) {
        guard !inFlight.contains(key) else {
            return
        }

        inFlight.insert(key)
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                self.inFlight.remove(key)
            }

            let data = await self.downloadFaviconData(for: pageURL)
            guard
                let data,
                let image = NSImage(data: data),
                let pngData = Self.pngData(from: image)
            else {
                self.recordResult(key: key, success: false)
                return
            }

            do {
                try FileManager.default.createDirectory(
                    at: self.cacheDirectory,
                    withIntermediateDirectories: true
                )
                try pngData.write(to: fileURL, options: [.atomic])
                self.recordResult(key: key, success: true)
                self.version &+= 1
                self.onIconLoaded?()
            } catch {
                self.recordResult(key: key, success: false)
            }
        }
    }

    private func downloadFaviconData(for pageURL: URL) async -> Data? {
        // Strategy: fetch the page HTML first and rank discovered icons by
        // declared `sizes`, falling back to the well-known root paths if the
        // page has no usable hints (or fails to load).
        if let html = await downloadText(from: pageURL) {
            for url in discoveredIconURLs(in: html, baseURL: pageURL) {
                if let data = await downloadImageData(from: url) {
                    return data
                }
            }
        }

        for url in directFaviconURLs(for: pageURL) {
            if let data = await downloadImageData(from: url) {
                return data
            }
        }
        return nil
    }

    private func directFaviconURLs(for pageURL: URL) -> [URL] {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else {
            return []
        }

        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let origin = components.url else {
            return []
        }

        return [
            origin.appendingPathComponent("apple-touch-icon.png"),
            origin.appendingPathComponent("favicon.png"),
            origin.appendingPathComponent("favicon.ico")
        ]
    }

    private func downloadImageData(from url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url) else {
            return nil
        }

        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            NSImage(data: data) != nil
        else {
            return nil
        }

        return data
    }

    private func downloadText(from url: URL) async -> String? {
        guard let (data, response) = try? await session.data(from: url) else {
            return nil
        }

        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Parse all `<link rel="...icon...">` tags, score by declared size, and
    /// return URLs sorted best-first. Apple-touch-icons get a small bonus
    /// since they are reliably square and high-DPI; mask-icons (monochrome
    /// SVG glyphs) get a penalty since they render badly as menu favicons.
    private func discoveredIconURLs(in html: String, baseURL: URL) -> [URL] {
        let linkPattern = #"(?s)<link\b[^>]*>"#
        let attrPattern = #"(?s)([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#

        guard
            let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive]),
            let attrRegex = try? NSRegularExpression(pattern: attrPattern, options: [.caseInsensitive])
        else {
            return []
        }

        struct Candidate {
            var score: Int
            var url: URL
        }

        var candidates: [Candidate] = []
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)

        for match in linkRegex.matches(in: html, range: fullRange) {
            guard let linkRange = Range(match.range, in: html) else { continue }
            let tag = String(html[linkRange])
            let tagNS = NSRange(tag.startIndex..<tag.endIndex, in: tag)

            var attrs: [String: String] = [:]
            for attrMatch in attrRegex.matches(in: tag, range: tagNS) {
                guard let nameRange = Range(attrMatch.range(at: 1), in: tag) else { continue }
                let name = tag[nameRange].lowercased()
                let value: String
                if let r = Range(attrMatch.range(at: 2), in: tag) {
                    value = String(tag[r])
                } else if let r = Range(attrMatch.range(at: 3), in: tag) {
                    value = String(tag[r])
                } else if let r = Range(attrMatch.range(at: 4), in: tag) {
                    value = String(tag[r])
                } else {
                    continue
                }
                attrs[name] = value
            }

            guard
                let rel = attrs["rel"]?.lowercased(),
                rel.contains("icon"),
                let href = attrs["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !href.isEmpty,
                let url = URL(string: href, relativeTo: baseURL)?.absoluteURL
            else {
                continue
            }

            let isAppleTouch = rel.contains("apple-touch-icon")
            let isMask = rel.contains("mask-icon")
            let dim = parseSizeAttribute(attrs["sizes"])
            // Score: declared dimension dominates; type provides a tiebreak.
            var score = dim
            if isAppleTouch { score += 64 }
            if isMask { score -= 10_000 }
            candidates.append(Candidate(score: score, url: url))
        }

        // Stable sort, best-first; dedupe by URL.
        var seen = Set<URL>()
        return candidates
            .sorted { $0.score > $1.score }
            .filter { seen.insert($0.url).inserted }
            .map { $0.url }
    }

    /// Parse a `sizes` attribute like "32x32 64x64" or "any". Returns the
    /// largest declared edge length, or 0 if unknown. "any" is treated as a
    /// large value so SVG icons rank above tiny rasters.
    private func parseSizeAttribute(_ raw: String?) -> Int {
        guard let raw = raw?.lowercased() else { return 0 }
        if raw.contains("any") { return 1024 }
        var maxDim = 0
        for token in raw.split(whereSeparator: { $0.isWhitespace }) {
            let parts = token.split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { continue }
            maxDim = max(maxDim, min(w, h))
        }
        return maxDim
    }

    private func cacheKey(for url: URL) -> String? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host?.lowercased()
        else {
            return nil
        }

        let identity = components.port.map { "\(host):\($0)" } ?? host
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Index persistence

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: FaviconRecord].self, from: data) {
            index = decoded
        }
    }

    private func recordResult(key: String, success: Bool) {
        index[key] = FaviconRecord(fetchedAt: Date(), success: success)
        saveIndex()
    }

    private func saveIndex() {
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(index)
            try data.write(to: indexURL, options: [.atomic])
        } catch {
            // Index is a cache; losing it just means we'll re-test more sites.
        }
    }
}

@MainActor
final class BookmarkFileWatcher {
    private let fileURL: URL
    private let onChange: () -> Void
    private var fileDescriptor: CInt = -1
    private var directoryDescriptor: CInt = -1
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var restartPending = false

    init(fileURL: URL, onChange: @escaping () -> Void) {
        self.fileURL = fileURL
        self.onChange = onChange
        start()
    }

    private func start() {
        if restartPending { return }
        let hadSources = fileSource != nil || directorySource != nil
        stop()
        if hadSources {
            // Cancel handlers run on .main; defer reopen to a later main-queue
            // tick so that orphan handlers close their original fds before we
            // open new ones (avoids fd-number reuse closing the wrong fd).
            restartPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.restartPending = false
                self.openSources()
            }
        } else {
            openSources()
        }
    }

    private func openSources() {
        watchFile()
        watchDirectory()
    }

    private func stop() {
        // fds are owned by the dispatch sources; their cancel handlers will
        // close them. Only fall back to a direct close when no source exists.
        if let fileSource {
            fileSource.cancel()
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
        }

        if let directorySource {
            directorySource.cancel()
        } else if directoryDescriptor >= 0 {
            close(directoryDescriptor)
        }

        fileSource = nil
        directorySource = nil
        fileDescriptor = -1
        directoryDescriptor = -1
    }

    private func watchFile() {
        fileDescriptor = open(fileURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.handleFileEvent()
        }
        source.setCancelHandler { [fileDescriptor] in
            if fileDescriptor >= 0 {
                close(fileDescriptor)
            }
        }
        fileSource = source
        source.resume()
    }

    private func watchDirectory() {
        directoryDescriptor = open(fileURL.deletingLastPathComponent().path, O_EVTONLY)
        guard directoryDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.handleDirectoryEvent()
        }
        source.setCancelHandler { [directoryDescriptor] in
            if directoryDescriptor >= 0 {
                close(directoryDescriptor)
            }
        }
        directorySource = source
        source.resume()
    }

    private func handleFileEvent() {
        let flags = fileSource?.data ?? []
        if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
            start()
        }

        scheduleReload()
    }

    private func handleDirectoryEvent() {
        if fileSource == nil || !FileManager.default.fileExists(atPath: fileURL.path) {
            start()
        }

        scheduleReload()
    }

    private func scheduleReload() {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
}
