import AppKit
import Foundation
import KeyboardShortcuts
import ObeliskCore
import ObeliskData
import ObeliskRuntime
import ObeliskSync
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var store: BookmarkStore!
  private var cloudSync: CloudSyncController!
  private var runtime: RuntimeHost!
  private var managerWindow: BookmarkManagerWindowController!
  private lazy var faviconLoader = FaviconLoader(rootDirectory: store.rootDirectory)
  private lazy var menuBar = BookmarkStatusMenuController(
    library: LibraryClient(store: store), faviconLoader: faviconLoader)
  private lazy var bookmarkFeedbackPanel = BookmarkFeedbackPanelController { [weak self] in
    self?.menuBar.feedbackAnchorView
  }
  private lazy var updaterController = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  private var aiFeaturesEnabled: Bool {
    UserDefaults.standard.object(forKey: BookmarksModel.aiFeaturesEnabledKey) as? Bool ?? true
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    ApplicationMenu.install(
      updaterController: updaterController, target: self, openManager: #selector(openManager),
      newBookmark: #selector(newBookmarkFromMenu(_:)),
      toggleHiddenBookmarksSidebar: #selector(toggleHiddenBookmarksSidebarFromMenu(_:)))
    Task { await startApplication() }
  }
  private func startApplication() async {
    do { store = try BookmarkStore.open(deviceID: ObeliskDeviceIdentity.current()) } catch {
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = "Obelisk 无法启动"
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: "退出")
      alert.runModal()
      NSApp.terminate(nil)
      return
    }
    cloudSync = CloudSyncController(database: store.database)
    await cloudSync.start()
    runtime = RuntimeHost(store: store, sync: cloudSync, icons: faviconLoader)
    runtime.onRelaunch = { AppRelauncher.relaunch() }
    managerWindow = BookmarkManagerWindowController(runtime: runtime)
    runtime.onLibraryChange = { [weak self] in self?.menuBar.scheduleRebuild() }
    faviconLoader.onIconLoaded = { [weak self] key in
      self?.menuBar.refreshFavicon(key: key)
      self?.managerWindow.send(RuntimeEvent(.favicon, value: key))
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(defaultsDidChange(_:)), name: UserDefaults.didChangeNotification,
      object: UserDefaults.standard)
    installKeyboardShortcutHandlers()
    menuBar.rebuildMenu()
    _ = applicationOpenUntitledFile(NSApp)
  }
  func applicationDidBecomeActive(_ notification: Notification) { cloudSync?.resume() }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard
      managerWindow?.prepareToTerminate(completion: {
        Task { @MainActor in sender.reply(toApplicationShouldTerminate: true) }
      }) == true
    else { return .terminateNow }
    return .terminateLater
  }
  func applicationWillTerminate(_ notification: Notification) {
    NotificationCenter.default.removeObserver(self)
    runtime?.stop()
  }
  @objc nonisolated private func defaultsDidChange(_ notification: Notification) {
    Task { @MainActor [weak self] in
      guard let self, runtime != nil else { return }
      menuBar.configureStatusItemAppearance()
      menuBar.scheduleRebuild()
      managerWindow.send(RuntimeEvent(.preferences, data: RuntimeHost.preferencesData()))
    }
  }
  private func addBookmark(title: String, url: String, isHidden: Bool) -> Result<
    Bookmark, any Error
  > {
    do {
      guard isHidden || !HiddenBookmarkKeywordExclusion.matches(url: url) else {
        throw RuntimeError.remote(HiddenBookmarkKeywordExclusion.blockedBookmarkMessage)
      }
      let bookmark = try LibraryClient(store: store).add(title: title, url: url, isHidden: isHidden)
      cloudSync.resume()
      return .success(bookmark)
    } catch { return .failure(error) }
  }
  /// Global shortcuts fetch the frontmost browser tab without opening the UI
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
    guard case .resolved(let url, let title) = resolved else {
      if case .failed(let message, let settingsDestination) = resolved {
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
    switch addBookmark(title: resolvedTitle, url: url, isHidden: isHidden) {
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
      let outcome = await runtime.optimize(ids: [bookmark.id])
      showBookmarkFeedback(
        title: "Intelligence 书签优化",
        subtitle: outcome.summary,
        kind: outcome.didChange ? .intelligence : .error
      )
    }
  }

  private func showBookmarkFeedback(title: String, subtitle: String, kind: BookmarkFeedbackKind) {
    bookmarkFeedbackPanel.show(
      BookmarkFeedbackPresentation(title: title, subtitle: subtitle, kind: kind))
  }
  @objc private func openManager() {
    guard managerWindow != nil else { return }
    managerWindow.show()
  }
  @objc private func newBookmarkFromMenu(_ sender: Any?) {
    openManager()
    managerWindow?.send(RuntimeEvent(.add))
  }
  @objc private func toggleHiddenBookmarksSidebarFromMenu(_ sender: Any?) {
    ObeliskAppDefaults.toggleShowHiddenBookmarksPage()
  }
  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
  func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
    openManager()
    return true
  }
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
}

ObeliskAppDefaults.register()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
