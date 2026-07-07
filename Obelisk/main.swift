import AppKit
import Carbon.HIToolbox
import CoreSpotlight
import KeyboardShortcuts
import Foundation
import Observation
import os
import Sparkle
import SwiftUI

private let inputSourceLog = Logger(subsystem: "com.eli.Obelisk", category: "InputSource")
private let isUITesting = CommandLine.arguments.contains("-uiTesting")

@objc
private protocol StandardMenuActionSelectors {
    func print(_ sender: Any?)
    func setSearchString(_ sender: Any?)
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

private func configureUITestingEnvironmentIfNeeded() {
    guard isUITesting else { return }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ObeliskUITests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    setenv("OBELISK_HOME", root.path, 1)
    LocalJSONEncryption.isEnabled = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private let maxMenuTitlePixelWidth: CGFloat = 300
    private let undoWindowSeconds: TimeInterval = 5
    private static let destructiveMenuItemIdentifier = NSUserInterfaceItemIdentifier("ObeliskDestructiveMenuItem")
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = BookmarkStore()
    private let usageStore = UsageStore()
    private var bookmarkWatcher: BookmarkFileWatcher?
    private var rebuildDebounce: DispatchWorkItem?
    private lazy var bookmarksModel = BookmarksModel(
        store: store,
        usageStore: usageStore,
        recentGroupLimit: UserDefaults.standard.object(forKey: "menuRecentGroupLimit") as? Int ?? 5
    )
    private let addRequest = AddBookmarkRequest()
    private lazy var managerWindow = BookmarkManagerWindowController(
        model: bookmarksModel,
        faviconLoader: faviconLoader,
        addRequest: addRequest,
        onStorageRootChanged: { [weak self] rootDirectory in
            self?.handleStorageRootChanged(rootDirectory)
        }
    )
    private lazy var faviconLoader: FaviconLoader = {
        let loader = FaviconLoader(rootDirectory: store.rootDirectory)
        loader.onIconLoaded = { [weak self] in
            self?.scheduleRebuild()
        }
        return loader
    }()
    private var pendingOptimizationTask: Task<Void, Never>?
    private var aiFeaturesEnabled: Bool {
        UserDefaults.standard.object(forKey: BookmarksModel.aiFeaturesEnabledKey) as? Bool ?? true
    }
    private var notificationPopover: NSPopover?
    private var notificationDismissWorkItem: DispatchWorkItem?
    private var searchPopover: NSPopover?
    private let searchInputSourceSwitcher = InputSourceSwitcher()
    private var searchCommandBridge: MenuBarSearchCommandBridge?
    private var searchKeyMonitor: Any?
    private var statusMenu: NSMenu?
    private var suppressStatusItemClickUntil: Date?
    private var pendingUndo: PendingBookmarkUndo?
    private var pendingUndoExpirationWorkItem: DispatchWorkItem?
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private struct PendingBookmarkUndo {
        let bookmark: Bookmark
        let expiresAt: Date
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let storageRoot = BookmarkStore.defaultRootDirectory()
        if LocalJSONEncryption.isEnabled {
            _ = KeychainEncryptionKeyStore().recoverEncryptionKeyIfNeeded(rootDirectory: storageRoot)
        }
        ObeliskKeychainMigration.migrateIfNeeded()
        installMainMenu()
        configureStatusItem()
        installDefaultsObserver()
        clearLegacySpotlightIndex()
        clearLegacyICloudDefaults()
        bookmarksModel.onChange = { [weak self] in
            self?.scheduleRebuild()
        }
        startBookmarkWatcher()
        normalizeActiveStorageRoot()
        installKeyboardShortcutHandlers()
        rebuildMenu()
        setupNotificationPopover()

        openManager()
    }

    func applicationDidResignActive(_ notification: Notification) {
        dismissMenuBarSearchPopover()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        usageStore.flushPendingWrites()
    }

    private func installDefaultsObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    @objc private func defaultsDidChange(_ notification: Notification) {
        configureStatusItem()
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
        KeyboardShortcuts.onKeyUp(for: .undoAdd) { [weak self] in
            self?.undoLastAdd()
        }
        KeyboardShortcuts.onKeyUp(for: .menuBarSearch) { [weak self] in
            self?.showMenuBarSearchPopover()
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
                notifyUser(
                    title: "无法添加书签",
                    body: message,
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
            notifyUser(
                title: "添加失败",
                body: error.localizedDescription,
                kind: .error
            )
            return
        }

        let bookmarkType = bookmark.isHidden ? "隐藏书签" : "书签"
        armUndo(for: bookmark)
        notifyUser(
            title: "已添加\(bookmarkType)",
            body: resolvedTitle,
            kind: bookmark.isHidden ? .hidden : .success
        )

        guard aiFeaturesEnabled else { return }

        let options = BookmarkIntelligenceOptimizationOptions.automatic(for: bookmark)
        guard options.optimizeTitles || options.autoGroup else { return }

        pendingOptimizationTask?.cancel()
        pendingOptimizationTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await bookmarksModel.optimizeBookmarks(
                bookmarkIds: [bookmark.id],
                options: options
            )
            notifyUser(
                title: "Intelligence 书签优化",
                body: outcome.summary,
                kind: outcome.didChange ? .intelligence : .error
            )
        }
    }

    private func armUndo(for bookmark: Bookmark) {
        pendingUndoExpirationWorkItem?.cancel()
        pendingUndo = PendingBookmarkUndo(
            bookmark: bookmark,
            expiresAt: Date().addingTimeInterval(undoWindowSeconds)
        )

        let work = DispatchWorkItem { [weak self] in
            self?.pendingUndo = nil
            self?.pendingUndoExpirationWorkItem = nil
        }
        pendingUndoExpirationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + undoWindowSeconds, execute: work)
    }

    private func undoLastAdd() {
        guard let pendingUndo, Date() <= pendingUndo.expiresAt else {
            self.pendingUndo = nil
            pendingUndoExpirationWorkItem?.cancel()
            pendingUndoExpirationWorkItem = nil
            return
        }

        self.pendingUndo = nil
        pendingUndoExpirationWorkItem?.cancel()
        pendingUndoExpirationWorkItem = nil
        pendingOptimizationTask?.cancel()

        if let error = bookmarksModel.delete(id: pendingUndo.bookmark.id) {
            notifyUser(
                title: "撤回失败",
                body: error,
                kind: .error
            )
        } else {
            notifyUser(
                title: "已撤回添加",
                body: pendingUndo.bookmark.title,
                kind: .undo
            )
        }
    }

    // MARK: - Menu bar notification dispatch

    private func notifyUser(
        title: String,
        body: String,
        kind: BookmarkAddedNotificationView.Kind
    ) {
        dismissNotificationPopover()
        showMenuBarPopover(title: title, subtitle: body, kind: kind)
    }

    private func dismissNotificationPopover() {
        notificationDismissWorkItem?.cancel()
        notificationDismissWorkItem = nil
        notificationPopover?.performClose(nil)
        notificationPopover?.close()
        notificationPopover = nil
    }

    private func showMenuBarSearchPopover() {
        dismissNotificationPopover()

        if searchPopover?.isShown == true {
            dismissMenuBarSearchPopover()
            return
        }

        guard let button = statusItem.button else { return }

        NSApp.activate(ignoringOtherApps: true)

        let commandBridge = MenuBarSearchCommandBridge()
        searchCommandBridge = commandBridge
        installMenuBarSearchKeyMonitor(commandBridge: commandBridge)

        let contentView = MenuBarBookmarkSearchView(
            model: bookmarksModel,
            faviconLoader: faviconLoader,
            showsURLHostOnly: UserDefaults.standard.bool(forKey: "showsURLHostOnly"),
            commandBridge: commandBridge,
            onOpen: { [weak self] bookmark in
                self?.bookmarksModel.openBookmark(bookmark)
            },
            onClose: { [weak self] in
                self?.dismissMenuBarSearchPopover()
            }
        )
        let hosting = NSHostingController(rootView: contentView)

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 420, height: 520)
        searchPopover = popover
        statusItem.menu = nil

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        searchInputSourceSwitcher.switchToUSEnglish()
        DispatchQueue.main.async { [weak popover, searchInputSourceSwitcher] in
            searchInputSourceSwitcher.switchToUSEnglish()
            Self.focusSearchField(in: popover?.contentViewController?.view)
        }
    }

    private func dismissMenuBarSearchPopover() {
        let popover = searchPopover
        popover?.performClose(nil)
        popover?.close()
        if let popover, searchPopover === popover {
            searchPopover = nil
        }
        uninstallMenuBarSearchKeyMonitor()
        searchCommandBridge = nil
    }

    private func installMenuBarSearchKeyMonitor(commandBridge: MenuBarSearchCommandBridge) {
        uninstallMenuBarSearchKeyMonitor()
        searchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak commandBridge] event in
            guard let self,
                  let commandBridge,
                  self.searchPopover?.isShown == true
            else {
                return event
            }

            let popoverWindow = self.searchPopover?.contentViewController?.view.window
            let eventWindow = event.window ?? popoverWindow
            switch MenuBarSearchKeyCommand.command(
                for: event,
                hasMarkedText: Self.firstResponderHasMarkedText(in: eventWindow)
            ) {
            case .close:
                commandBridge.reset()
                return nil
            case .open:
                commandBridge.open(query: Self.currentText(
                    in: eventWindow,
                    fallbackView: self.searchPopover?.contentViewController?.view
                ))
                return nil
            case .passThrough:
                return event
            }
        }
    }

    private func uninstallMenuBarSearchKeyMonitor() {
        guard let searchKeyMonitor else { return }
        NSEvent.removeMonitor(searchKeyMonitor)
        self.searchKeyMonitor = nil
    }

    private static func firstResponderHasMarkedText(in window: NSWindow?) -> Bool {
        guard let firstResponder = window?.firstResponder as? NSTextView else { return false }
        return firstResponder.hasMarkedText()
    }

    private static func currentText(in window: NSWindow?, fallbackView: NSView?) -> String? {
        if let firstResponder = window?.firstResponder {
            if let textView = firstResponder as? NSTextView {
                return textView.string
            }
            if let searchField = firstResponder as? NSSearchField {
                return searchField.stringValue
            }
            if let view = firstResponder as? NSView,
               let searchField = sequence(first: view, next: \.superview)
                .compactMap({ $0 as? NSSearchField })
                .first {
                return searchField.stringValue
            }
        }

        return searchField(in: fallbackView)?.stringValue
    }

    private static func focusSearchField(in view: NSView?, remainingAttempts: Int = 6) {
        guard let view else { return }
        if let searchField = searchField(in: view), let window = searchField.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            if window.makeFirstResponder(searchField) {
                return
            }
        }

        guard remainingAttempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusSearchField(in: view, remainingAttempts: remainingAttempts - 1)
        }
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let searchField = view as? NSSearchField {
            return searchField
        }
        for subview in view.subviews {
            if let searchField = searchField(in: subview) {
                return searchField
            }
        }
        return nil
    }

    // MARK: - Menu bar popover notification

    private func setupNotificationPopover() {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        notificationPopover = popover
    }

    private func showMenuBarPopover(
        title: String,
        subtitle: String,
        kind: BookmarkAddedNotificationView.Kind
    ) {
        guard let button = statusItem.button else { return }

        let contentView = BookmarkAddedNotificationView(
            title: title,
            subtitle: subtitle,
            kind: kind
        )

        let hosting = NSHostingController(rootView: contentView)
        // Force layout so the popover knows its exact content size before we
        // call show().  Without this the popover's arrow points at the button
        // but the body is positioned far below it.
        hosting.view.frame = NSRect(x: 0, y: 0, width: 280, height: 200)
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 280, height: fitted.height)
        notificationPopover = popover

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Keep success messages visible for the whole undo window.
        let work = DispatchWorkItem { [weak self] in
            self?.dismissNotificationPopover()
        }
        notificationDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + undoWindowSeconds, execute: work)
    }

    /// LSUIElement apps get no main menu by default, which means ⌘C/⌘V/⌘X/⌘A
    /// have nowhere to dispatch when a TextField is focused in our settings
    /// window. Install a full default macOS main menu (App/File/Edit/View/
    /// Window/Help) so the menu bar looks like a standard application and
    /// standard text-editing shortcuts route through the responder chain.
    ///
    /// All titles are resolved via NSLocalizedString; the matching English /
    /// Simplified Chinese strings live in en.lproj / zh-Hans.lproj.
    /// Standard AppKit selectors are used so macOS auto-disables items whose
    /// target is not in the responder chain (e.g. document actions in an
    /// accessory app) — they still render in the default style.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // MARK: App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: NSLocalizedString("About Obelisk", comment: "App menu"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        let checkForUpdatesItem = NSMenuItem(
            title: NSLocalizedString("Check for Updates…", comment: "App menu"),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = updaterController
        appMenu.addItem(checkForUpdatesItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: NSLocalizedString("Settings…", comment: "App menu"), action: #selector(openManager), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: NSLocalizedString("Hide Obelisk", comment: "App menu"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: NSLocalizedString("Hide Others", comment: "App menu"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: NSLocalizedString("Show All", comment: "App menu"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: NSLocalizedString("Quit Obelisk", comment: "App menu"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        // MARK: File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: NSLocalizedString("File", comment: "File menu title"))
        let newItem = NSMenuItem(title: NSLocalizedString("New Bookmark", comment: "File menu"), action: #selector(newBookmarkFromMenu(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)
        fileMenu.addItem(NSMenuItem(title: NSLocalizedString("Open…", comment: "File menu"), action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o"))
        let openRecentItem = NSMenuItem(title: NSLocalizedString("Open Recent", comment: "File menu"), action: nil, keyEquivalent: "")
        let openRecentSubmenu = NSMenu(title: NSLocalizedString("Open Recent", comment: "File menu"))
        openRecentSubmenu.autoenablesItems = false
        openRecentSubmenu.addItem(NSMenuItem(title: NSLocalizedString("Clear Menu", comment: "File menu"), action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: ""))
        openRecentItem.submenu = openRecentSubmenu
        fileMenu.addItem(openRecentItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: NSLocalizedString("Close", comment: "File menu"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileMenu.addItem(NSMenuItem(title: NSLocalizedString("Save", comment: "File menu"), action: #selector(NSDocument.save(_:)), keyEquivalent: "s"))
        let saveAsItem = NSMenuItem(title: NSLocalizedString("Save As…", comment: "File menu"), action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAsItem)
        fileMenu.addItem(NSMenuItem(title: NSLocalizedString("Revert To Saved", comment: "File menu"), action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: ""))
        fileMenu.addItem(.separator())
        let pageSetupItem = NSMenuItem(title: NSLocalizedString("Page Setup…", comment: "File menu"), action: #selector(NSDocument.runPageLayout(_:)), keyEquivalent: "p")
        pageSetupItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(pageSetupItem)
        fileMenu.addItem(NSMenuItem(title: NSLocalizedString("Print…", comment: "File menu"), action: #selector(StandardMenuActionSelectors.print(_:)), keyEquivalent: "p"))
        fileMenuItem.submenu = fileMenu

        // MARK: Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: "Edit menu title"))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("Undo", comment: "Edit menu"), action: #selector(StandardMenuActionSelectors.undo(_:)), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: NSLocalizedString("Redo", comment: "Edit menu"), action: #selector(StandardMenuActionSelectors.redo(_:)), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("Cut", comment: "Edit menu"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("Copy", comment: "Edit menu"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("Paste", comment: "Edit menu"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("Delete", comment: "Edit menu"), action: #selector(NSText.delete(_:)), keyEquivalent: "\u{8}"))
        editMenu.addItem(NSMenuItem(title: NSLocalizedString("Select All", comment: "Edit menu"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())

        // Find submenu
        let findItem = NSMenuItem(title: NSLocalizedString("Find", comment: "Edit menu"), action: nil, keyEquivalent: "")
        let findSubmenu = NSMenu(title: NSLocalizedString("Find", comment: "Edit menu"))
        findSubmenu.autoenablesItems = false
        let findPanelItem = NSMenuItem(title: NSLocalizedString("Find…", comment: "Edit menu"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findPanelItem.tag = 1
        findSubmenu.addItem(findPanelItem)
        let findNextItem = NSMenuItem(title: NSLocalizedString("Find Next", comment: "Edit menu"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        findNextItem.tag = 2
        findSubmenu.addItem(findNextItem)
        let findPrevItem = NSMenuItem(title: NSLocalizedString("Find Previous", comment: "Edit menu"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        findPrevItem.tag = 3
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findSubmenu.addItem(findPrevItem)
        let useSelectionItem = NSMenuItem(title: NSLocalizedString("Use Selection for Find", comment: "Edit menu"), action: #selector(StandardMenuActionSelectors.setSearchString(_:)), keyEquivalent: "e")
        useSelectionItem.keyEquivalentModifierMask = [.command, .option]
        findSubmenu.addItem(useSelectionItem)
        let jumpToSelectionItem = NSMenuItem(title: NSLocalizedString("Jump to Selection", comment: "Edit menu"), action: #selector(NSResponder.centerSelectionInVisibleArea(_:)), keyEquivalent: "j")
        jumpToSelectionItem.keyEquivalentModifierMask = [.command, .option]
        findSubmenu.addItem(jumpToSelectionItem)
        findItem.submenu = findSubmenu
        editMenu.addItem(findItem)

        // Spelling and Grammar submenu
        let spellingItem = NSMenuItem(title: NSLocalizedString("Spelling and Grammar", comment: "Edit menu"), action: nil, keyEquivalent: "")
        let spellingSubmenu = NSMenu(title: NSLocalizedString("Spelling and Grammar", comment: "Edit menu"))
        spellingSubmenu.autoenablesItems = false
        spellingSubmenu.addItem(NSMenuItem(title: NSLocalizedString("Check Spelling Now", comment: "Edit menu"), action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";"))
        let checkSpellingItem = NSMenuItem(title: NSLocalizedString("Check Spelling While Typing", comment: "Edit menu"), action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: ":")
        checkSpellingItem.keyEquivalentModifierMask = [.command, .shift]
        spellingSubmenu.addItem(checkSpellingItem)
        spellingSubmenu.addItem(.separator())
        let showSpellingItem = NSMenuItem(title: NSLocalizedString("Show Spelling and Grammar", comment: "Edit menu"), action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        showSpellingItem.keyEquivalentModifierMask = [.command, .shift]
        spellingSubmenu.addItem(showSpellingItem)
        spellingItem.submenu = spellingSubmenu
        editMenu.addItem(spellingItem)

        // Substitutions submenu
        let substitutionsItem = NSMenuItem(title: NSLocalizedString("Substitutions", comment: "Edit menu"), action: nil, keyEquivalent: "")
        let substitutionsSubmenu = NSMenu(title: NSLocalizedString("Substitutions", comment: "Edit menu"))
        substitutionsSubmenu.autoenablesItems = false
        substitutionsSubmenu.addItem(NSMenuItem(title: NSLocalizedString("Show Substitutions", comment: "Edit menu"), action: #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), keyEquivalent: ""))
        substitutionsSubmenu.addItem(.separator())
        substitutionsSubmenu.addItem(NSMenuItem(title: NSLocalizedString("Smart Copy/Paste", comment: "Edit menu"), action: #selector(NSTextView.toggleSmartInsertDelete(_:)), keyEquivalent: ""))
        substitutionsSubmenu.addItem(NSMenuItem(title: NSLocalizedString("Smart Quotes", comment: "Edit menu"), action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: ""))
        substitutionsSubmenu.addItem(NSMenuItem(title: NSLocalizedString("Smart Dashes", comment: "Edit menu"), action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: ""))
        substitutionsSubmenu.addItem(NSMenuItem(title: NSLocalizedString("Smart Links", comment: "Edit menu"), action: #selector(NSTextView.toggleAutomaticLinkDetection(_:)), keyEquivalent: ""))
        substitutionsSubmenu.addItem(NSMenuItem(title: NSLocalizedString("Text Replacement", comment: "Edit menu"), action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: ""))
        substitutionsItem.submenu = substitutionsSubmenu
        editMenu.addItem(substitutionsItem)

        // Speech submenu
        let speechItem = NSMenuItem(title: NSLocalizedString("Speech", comment: "Edit menu"), action: nil, keyEquivalent: "")
        let speechSubmenu = NSMenu(title: NSLocalizedString("Speech", comment: "Edit menu"))
        speechSubmenu.autoenablesItems = false
        speechSubmenu.addItem(NSMenuItem(title: NSLocalizedString("Start Speaking", comment: "Edit menu"), action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: ""))
        speechSubmenu.addItem(NSMenuItem(title: NSLocalizedString("Stop Speaking", comment: "Edit menu"), action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: ""))
        speechItem.submenu = speechSubmenu
        editMenu.addItem(speechItem)

        editMenu.addItem(.separator())
        let emojiItem = NSMenuItem(title: NSLocalizedString("Emoji & Symbols", comment: "Edit menu"), action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: " ")
        emojiItem.keyEquivalentModifierMask = [.command, .control]
        editMenu.addItem(emojiItem)
        editMenuItem.submenu = editMenu

        // MARK: View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: NSLocalizedString("View", comment: "View menu title"))
        let showToolbarItem = NSMenuItem(title: NSLocalizedString("Show Toolbar", comment: "View menu"), action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t")
        showToolbarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(showToolbarItem)
        let customizeToolbarItem = NSMenuItem(title: NSLocalizedString("Customize Toolbar…", comment: "View menu"), action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
        viewMenu.addItem(customizeToolbarItem)
        viewMenu.addItem(.separator())
        let fullScreenItem = NSMenuItem(title: NSLocalizedString("Enter Full Screen", comment: "View menu"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)
        viewMenuItem.submenu = viewMenu

        // MARK: Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: NSLocalizedString("Window", comment: "Window menu title"))
        windowMenu.addItem(NSMenuItem(title: NSLocalizedString("Minimize", comment: "Window menu"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let zoomItem = NSMenuItem(title: NSLocalizedString("Zoom", comment: "Window menu"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "z")
        zoomItem.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(zoomItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: NSLocalizedString("Bring All to Front", comment: "Window menu"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // MARK: Help menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: NSLocalizedString("Help", comment: "Help menu title"))
        let helpItem = NSMenuItem(title: NSLocalizedString("Obelisk Help", comment: "Help menu"), action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        helpItem.keyEquivalentModifierMask = [.command, .shift]
        helpMenu.addItem(helpItem)
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = AppIcon.menuBarImage()
            button.title = ""
            button.refusesFirstResponder = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if shouldSuppressStatusItemClickAfterMenuClose() {
            return
        }

        dismissNotificationPopover()

        if searchPopover?.isShown == true {
            if let event = NSApp.currentEvent,
               event.type == .keyDown || event.type == .keyUp {
                let popoverView = searchPopover?.contentViewController?.view
                let popoverWindow = popoverView?.window
                switch MenuBarSearchKeyCommand.command(
                    for: event,
                    hasMarkedText: Self.firstResponderHasMarkedText(in: popoverWindow)
                ) {
                case .close:
                    searchCommandBridge?.reset()
                case .open:
                    searchCommandBridge?.open(query: Self.currentText(
                        in: popoverWindow,
                        fallbackView: popoverView
                    ))
                case .passThrough:
                    Self.focusSearchField(in: popoverView)
                }
            } else {
                dismissMenuBarSearchPopover()
            }
            return
        }

        dismissMenuBarSearchPopover()

        guard let menu = statusMenu else {
            rebuildMenu()
            if let menu = statusMenu {
                showStatusMenu(menu)
            }
            return
        }

        showStatusMenu(menu)
    }

    private func showStatusMenu(_ menu: NSMenu) {
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
    }

    private func shouldSuppressStatusItemClickAfterMenuClose() -> Bool {
        guard let suppressStatusItemClickUntil else { return false }
        self.suppressStatusItemClickUntil = nil
        return Date() <= suppressStatusItemClickUntil
    }

    private func clearLegacySpotlightIndex() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [
            "com.eli.Obelisk.bookmarks",
            "com.eli.UniBookmark.bookmarks"
        ]) { _ in }
    }

    private func clearLegacyICloudDefaults() {
        UserDefaults.standard.removeObject(forKey: "syncWithICloudDrive")
        UserDefaults.standard.removeObject(forKey: "iCloudDocumentSyncRootPath")
    }

    private func startBookmarkWatcher() {
        bookmarkWatcher = BookmarkFileWatcher(fileURL: store.fileURL) { [weak self] in
            // model.reload fires onChange → menubar rebuild via the callback
            // wired in applicationDidFinishLaunching.
            self?.bookmarksModel.invalidateStorageCaches()
            self?.bookmarksModel.reload()
        }
    }

    private func handleStorageRootChanged(_ rootDirectory: URL) {
        bookmarksModel.updateStorageRootDirectory(rootDirectory)
        faviconLoader.updateRootDirectory(rootDirectory)
        bookmarkWatcher = nil
        startBookmarkWatcher()
        scheduleRebuild()
    }

    private func normalizeActiveStorageRoot() {
        let rootDirectory = store.rootDirectory
        let encrypted = LocalJSONEncryption.isEnabled
        Task.detached(priority: .utility) {
            do {
                try ObeliskStorageMigrator.normalizeStorage(in: rootDirectory, encrypted: encrypted)
                await MainActor.run { [weak self] in
                    self?.bookmarksModel.invalidateStorageCaches()
                    self?.faviconLoader.reloadStorage()
                    self?.bookmarksModel.reload()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.bookmarksModel.errorMessage = error.localizedDescription
                }
            }
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
        bookmarksModel.applyAutoArchiveIfNeeded()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let renderSections = bookmarksModel.menuRenderSections()

        if let error = bookmarksModel.loadErrorMessage {
            let errorItem = NSMenuItem(title: "读取失败: \(error)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        } else if renderSections.isEmpty {
            let header = NSMenuItem(title: "书签", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(NSMenuItem.separator())
            let emptyItem = NSMenuItem(title: "暂无书签", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for section in renderSections {
                switch section.presentation {
                case .inline:
                    appendSection(title: section.title, bookmarks: section.bookmarks, to: menu)
                case .reference:
                    appendSection(title: section.title, bookmarks: section.bookmarks, to: menu, isReference: true)
                case .submenu:
                    appendBookmarkSubmenu(title: section.title, bookmarks: section.bookmarks, to: menu)
                }
            }
        }

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        quitItem.identifier = Self.destructiveMenuItemIdentifier
        applyDestructiveMenuItemStyle(to: quitItem, highlighted: false)
        menu.addItem(quitItem)

        statusMenu = menu
        statusItem.menu = nil
    }

    private func appendSection(title: String, bookmarks: [Bookmark], to menu: NSMenu, isReference: Bool = false) {
        if menu.items.last != nil {
            menu.addItem(NSMenuItem.separator())
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for bookmark in bookmarks {
            menu.addItem(menuItem(for: bookmark, isReference: isReference))
        }
    }

    private func appendBookmarkSubmenu(title: String, bookmarks: [Bookmark], to menu: NSMenu) {
        if menu.items.last != nil {
            menu.addItem(NSMenuItem.separator())
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        for bookmark in bookmarks {
            submenu.addItem(menuItem(for: bookmark))
        }
        item.submenu = submenu
        menu.addItem(item)
    }

    private func menuItem(for bookmark: Bookmark, isReference: Bool = false) -> NSMenuItem {
        let title = truncatedTitle(bookmark.title)
        let item = NSMenuItem(
            title: title,
            action: #selector(openBookmark(_:)),
            keyEquivalent: ""
        )
        item.representedObject = bookmark
        let faviconEdge: CGFloat = 16
        let faviconSize = NSSize(width: faviconEdge, height: faviconEdge)
        let baseFavicon = faviconLoader.image(for: bookmark.url)
            ?? AppIcon.faviconPlaceholder(size: faviconSize)
        if isReference {
            item.image = FaviconReferenceBadge.composited(
                favicon: baseFavicon,
                faviconEdge: faviconEdge
            )
        } else {
            item.image = baseFavicon
        }
        return item
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items where menuItem.identifier == Self.destructiveMenuItemIdentifier {
            applyDestructiveMenuItemStyle(to: menuItem, highlighted: menuItem === item)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        dismissNotificationPopover()
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
        if mouseIsOverStatusItemButton {
            suppressStatusItemClickUntil = Date().addingTimeInterval(0.25)
        }
    }

    private var mouseIsOverStatusItemButton: Bool {
        guard let button = statusItem.button else { return false }
        let pointInWindow = button.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero
        let pointInButton = button.convert(pointInWindow, from: nil)
        return button.bounds.contains(pointInButton)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === searchPopover else {
            return
        }
        searchPopover = nil
        uninstallMenuBarSearchKeyMonitor()
        searchCommandBridge = nil
    }

    private func applyDestructiveMenuItemStyle(to item: NSMenuItem, highlighted: Bool) {
        item.attributedTitle = NSAttributedString(
            string: item.title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: highlighted ? NSColor.white : NSColor.systemRed
            ]
        )
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
        dismissNotificationPopover()
        managerWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// File menu → 新建书签. Mirrors the manager window toolbar "添加" button:
    /// opens the manager (if needed) and presents the add-bookmark sheet with
    /// empty fields, via the same AddBookmarkRequest channel the toolbar uses.
    @objc private func newBookmarkFromMenu(_ sender: Any?) {
        openManager()
        addRequest.request(url: nil, title: nil, isHidden: false)
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

configureUITestingEnvironmentIfNeeded()
ObeliskAppDefaults.register(preservesUnauthenticatedDisabledEncryption: isUITesting)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

@MainActor
enum MenuBarSearchKeyCommand: Equatable {
    case close
    case open
    case passThrough

    static func command(for event: NSEvent, hasMarkedText: Bool) -> MenuBarSearchKeyCommand {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.numericPad)
        guard modifiers.isEmpty, !hasMarkedText else { return .passThrough }

        switch event.keyCode {
        case UInt16(kVK_Escape):
            return .close
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            return .open
        default:
            return .passThrough
        }
    }
}

@MainActor
private final class InputSourceSwitcher {
    func switchToUSEnglish() {
        guard let inputSource = preferredEnglishInputSource() else {
            inputSourceLog.error("No enabled ASCII-capable keyboard input source found")
            return
        }

        let status = TISSelectInputSource(inputSource)
        if status != noErr {
            let inputSourceID = stringProperty(inputSource, kTISPropertyInputSourceID)
            inputSourceLog.error("Failed to select input source \(inputSourceID, privacy: .public): \(status)")
        }
    }

    private func preferredEnglishInputSource() -> TISInputSource? {
        let preferredIDs = [
            "com.apple.keylayout.ABC",
            "com.apple.keylayout.US",
            "com.apple.keylayout.USInternational-PC"
        ]

        for id in preferredIDs {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            guard
                let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
                let source = sources.first,
                isSelectableASCIIKeyboardLayout(source)
            else {
                continue
            }

            return source
        }

        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }

        return sources.first(where: isSelectableASCIIKeyboardLayout)
    }

    private func isSelectableASCIIKeyboardLayout(_ source: TISInputSource) -> Bool {
        stringProperty(source, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String)
            && stringProperty(source, kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String)
            && boolProperty(source, kTISPropertyInputSourceIsEnabled)
            && boolProperty(source, kTISPropertyInputSourceIsSelectCapable)
            && boolProperty(source, kTISPropertyInputSourceIsASCIICapable)
    }

    private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String {
        guard let rawValue = TISGetInputSourceProperty(source, key) else { return "" }
        return Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue() as String
    }

    private func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let rawValue = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(rawValue).takeUnretainedValue())
    }
}
