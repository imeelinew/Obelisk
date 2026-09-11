import AppKit
import Darwin
import KeyboardShortcuts
import Foundation
import ObeliskCore
import ObeliskData
import ObeliskSync
import Sparkle

private let isUITesting = CommandLine.arguments.contains("-uiTesting")
private let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil

private func configureTestingEnvironmentIfNeeded() {
    guard isUITesting || isUnitTesting else { return }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ObeliskTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    setenv("OBELISK_HOME", root.path, 1)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var menuBar = BookmarkStatusMenuController(
        model: bookmarksModel,
        faviconLoader: faviconLoader
    )
    private var store: BookmarkStore!
    private var cloudSync: CloudSyncController!
    private var databaseWatchTask: Task<Void, Never>?
    private lazy var bookmarksModel = BookmarksModel(
        store: store,
        recentGroupLimit: UserDefaults.standard.object(forKey: "menuRecentGroupLimit") as? Int ?? 5
    )
    private let addRequest = AddBookmarkRequest()
    private lazy var managerWindow = BookmarkManagerWindowController(
        model: bookmarksModel,
        cloudSync: cloudSync,
        faviconLoader: faviconLoader,
        addRequest: addRequest,
        onWindowClosed: { [weak self] in
            self?.handleManagerWindowClosed()
        }
    )
    private lazy var bookmarkFeedbackPanel = BookmarkFeedbackPanelController { [weak self] in
        self?.menuBar.feedbackAnchorView
    }
    private lazy var faviconLoader: FaviconLoader = {
        let loader = FaviconLoader(rootDirectory: store.rootDirectory)
        loader.onIconLoaded = { [weak self] in
            self?.menuBar.scheduleRebuild()
        }
        return loader
    }()
    private var aiFeaturesEnabled: Bool {
        UserDefaults.standard.object(forKey: BookmarksModel.aiFeaturesEnabledKey) as? Bool ?? true
    }
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: !isUITesting && !isUnitTesting,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        ApplicationMenu.install(
            updaterController: updaterController,
            target: self,
            openManager: #selector(openManager),
            newBookmark: #selector(newBookmarkFromMenu(_:)),
            toggleHiddenBookmarksSidebar: #selector(toggleHiddenBookmarksSidebarFromMenu(_:))
        )
        guard !isUnitTesting else { return }
        Task {
            await startApplication()
        }
    }

    private func startApplication() async {
        do {
            store = try BookmarkStore.open(
                deviceID: ObeliskDeviceIdentity.current()
            )
        } catch {
            presentStartupError(error)
            return
        }

        if isUITesting {
            // UI tests use an isolated database and must never read production
            // credentials or upload their fixtures to the configured server.
            cloudSync = CloudSyncController(
                database: store.database,
                defaults: UserDefaults(suiteName: store.rootDirectory.lastPathComponent)!
            )
        } else {
            cloudSync = CloudSyncController(database: store.database)
            await cloudSync.start()
        }

        installDefaultsObserver()
        bookmarksModel.onChange = { [weak self] in
            self?.menuBar.scheduleRebuild()
        }
        installKeyboardShortcutHandlers()
        menuBar.rebuildMenu()
        startDatabaseWatch()

        openManager()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isUITesting else { return }
        cloudSync?.resume()
    }

    private func presentStartupError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Obelisk 无法启动"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        databaseWatchTask?.cancel()
    }

    private func installDefaultsObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    @objc nonisolated private func defaultsDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.menuBar.configureStatusItemAppearance()
            self?.menuBar.scheduleRebuild()
        }
    }

    /// Global shortcuts (user-customizable in Settings) fetch the frontmost
    /// browser tab via AppleScript, or fall back to a clipboard http(s) URL.
    private func installKeyboardShortcutHandlers() {
        KeyboardShortcuts.onKeyUp(for: .addBookmark) { [weak self] in
            self?.handleGlobalHotkey(isHidden: false)
        }
        KeyboardShortcuts.onKeyUp(for: .addHiddenBookmark) { [weak self] in
            self?.handleGlobalHotkey(isHidden: true)
        }
        KeyboardShortcuts.onKeyUp(for: .toggleHiddenBookmarksSidebar) { [weak self] in
            self?.toggleHiddenBookmarksSidebarFromMenu(nil)
        }
    }

    private func handleGlobalHotkey(isHidden: Bool) {
        Task { [weak self] in
            let currentTab = await BrowserCurrentTab.fetch()
            self?.handleResolvedHotkeyTab(currentTab, isHidden: isHidden)
        }
    }

    private func handleResolvedHotkeyTab(_ currentTab: BrowserCurrentTabResult, isHidden: Bool) {
        let resolved = HotkeyBookmarkResolver.resolve(currentTab: currentTab)
        guard case let .resolved(url, title) = resolved else {
            if case let .failed(message, settingsDestination) = resolved {
                showBookmarkFeedback(
                    title: "无法添加书签",
                    subtitle: message,
                    kind: .error
                )
                if let settingsDestination {
                    PermissionSettingsGuide.open(settingsDestination)
                }
            }
            return
        }

        handleHotkeyAdd(url: url, title: title, isHidden: isHidden)
    }

    private func handleHotkeyAdd(url: String, title: String?, isHidden: Bool) {
        let resolvedTitle = (title?.isEmpty == false) ? title! : url
        let bookmark: Bookmark
        switch bookmarksModel.addBookmark(title: resolvedTitle, url: url, isHidden: isHidden) {
        case .success(let addedBookmark):
            bookmark = addedBookmark
        case .failure(let error):
            showBookmarkFeedback(
                title: "添加失败",
                subtitle: error.localizedDescription,
                kind: .error
            )
            return
        }

        let bookmarkType = bookmark.isHidden ? "隐藏书签" : "书签"
        showBookmarkFeedback(
            title: "已添加\(bookmarkType)",
            subtitle: resolvedTitle,
            kind: bookmark.isHidden ? .hidden : .success
        )

        guard aiFeaturesEnabled else { return }

        guard TitleOptimizationPreferences.allowsAutoOptimization(for: bookmark) else { return }

        Task { [weak self] in
            guard let self else { return }
            let outcome = await bookmarksModel.enqueueTitleOptimization(bookmarkIds: [bookmark.id])
            showBookmarkFeedback(
                title: "Intelligence 书签优化",
                subtitle: outcome.summary,
                kind: outcome.didChange ? .intelligence : .error
            )
        }
    }

    private func showBookmarkFeedback(
        title: String,
        subtitle: String,
        kind: BookmarkFeedbackKind
    ) {
        bookmarkFeedbackPanel.show(BookmarkFeedbackPresentation(
            title: title,
            subtitle: subtitle,
            kind: kind
        ))
    }

    private func startDatabaseWatch() {
        databaseWatchTask?.cancel()
        let database = store.database
        databaseWatchTask = Task { [weak self] in
            do {
                for try await _ in database.libraryChanges() {
                    guard !Task.isCancelled else { return }
                    self?.bookmarksModel.reload()
                }
            } catch {
                self?.bookmarksModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func handleManagerWindowClosed() {
        faviconLoader.releaseTransientMemory()
        DispatchQueue.main.async {
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    }

    @objc private func openManager() {
        guard store != nil else { return }
        managerWindow.show()
    }

    /// File menu → 新建书签. Mirrors the manager window toolbar "添加" button:
    /// opens the manager (if needed) and presents the add-bookmark sheet with
    /// empty fields, via the same AddBookmarkRequest channel the toolbar uses.
    @objc private func newBookmarkFromMenu(_ sender: Any?) {
        openManager()
        addRequest.request(url: nil, title: nil, isHidden: false)
    }

    @objc private func toggleHiddenBookmarksSidebarFromMenu(_ sender: Any?) {
        ObeliskAppDefaults.toggleShowHiddenBookmarksPage()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        openManager()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }
}

configureTestingEnvironmentIfNeeded()
ObeliskAppDefaults.register()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
