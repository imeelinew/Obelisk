import AppKit
import ExtensionFoundation
import ExtensionKit
@preconcurrency import KeyboardShortcuts
import ObeliskRuntime
import os

@MainActor
final class BookmarkManagerWindowController: NSObject, NSWindowDelegate,
  EXHostViewControllerDelegate, NSToolbarDelegate
{
  private let runtime: RuntimeHost
  private var window: NSWindow?
  private var sidebarTitlebarSpacer: SidebarTitlebarSpacer?
  private var hostView: BookmarkUIHostViewController?
  private var extensionProcess: AppExtensionProcess?
  private var connection: NSXPCConnection?
  private var launchTask: Task<Void, Never>?
  private var closingSessions: [UUID: ClosingUISession] = [:]
  private var terminationCompletion: (() -> Void)?
  private var pendingEvents: [RuntimeEvent] = []
  private var ready = false
  private var keyMonitor: Any?
  private var windowState = RuntimeWindowState(
    title: "书签", canAdd: true, addIsHidden: false, canEmptyTrash: false, showsTrash: false,
    transparent: false, detailLeading: 0)
  private let log = Logger(subsystem: "com.eli.Obelisk", category: "WindowRuntime")

  init(runtime: RuntimeHost) {
    self.runtime = runtime
    super.init()
    runtime.onWindowState = { [weak self] in self?.apply($0) }
    runtime.send = { [weak self] in self?.send($0) }
  }

  func show() {
    NSApp.setActivationPolicy(.regular)
    if let window {
      if window.alphaValue > 0 { window.makeKeyAndOrderFront(nil) }
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let host = BookmarkUIHostViewController()
    host.onTopInsetChanged = { [weak self] inset in
      guard let data = try? RuntimeCoding.encode(Double(inset)) else { return }
      self?.send(RuntimeEvent(.windowTopInset, data: data))
    }
    host.delegate = self
    let win = NSWindow(contentViewController: host)
    win.title = "书签".obeliskLocalized
    win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    win.collectionBehavior = [.fullScreenNone, .fullScreenDisallowsTiling]
    win.isReleasedWhenClosed = false
    win.minSize = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 950, height: 830)).size
    win.setFrame(NSRect(x: 0, y: 0, width: 950, height: 830), display: false)
    win.titlebarAppearsTransparent = true
    // ExtensionKit needs an ordered window to render its remote surface. Keep
    // that preparation invisible and non-interactive until the first frame arrives.
    win.alphaValue = 0
    win.ignoresMouseEvents = true
    let toolbar = NSToolbar(identifier: "ObeliskManagerToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    win.toolbar = toolbar
    let spacer = SidebarTitlebarSpacer()
    win.addTitlebarAccessoryViewController(spacer)
    sidebarTitlebarSpacer = spacer
    win.center()
    win.delegate = self
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let handled = MainActor.assumeIsolated {
        guard let self, event.window === self.window, event.modifierFlags.contains(.command) else {
          return false
        }
        // A remote first responder must not consume the containing app's menu shortcuts
        return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
      }
      return handled ? nil : event
    }
    window = win
    hostView = host
    win.orderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    launchTask = Task { [weak self] in
      guard let self else { return }
      do {
        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .obeliskUI)
        guard
          let identity = monitor.identities.first(where: {
            $0.bundleIdentifier == "com.eli.Obelisk.UI"
          })
        else {
          throw RuntimeError.remote("无法加载书签界面")
        }
        let process = try await AppExtensionProcess(
          configuration: .init(appExtensionIdentity: identity))
        guard !Task.isCancelled, self.window === win else {
          process.invalidate()
          return
        }
        self.extensionProcess = process
        host.configuration = .init(appExtension: identity, sceneID: "manager")
        self.log.info("UI process started")
      } catch {
        guard !Task.isCancelled else { return }
        self.log.error("UI launch failed: \(error.localizedDescription)")
        self.showLaunchFailure(error.localizedDescription, in: win)
      }
    }
  }

  func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
    guard let hostView, viewController === hostView else { return }
    do {
      let connection = try viewController.makeXPCConnection()
      connection.exportedInterface = NSXPCInterface(with: ObeliskHostEndpoint.self)
      connection.exportedObject = runtime
      connection.remoteObjectInterface = NSXPCInterface(with: ObeliskUIEndpoint.self)
      connection.resume()
      self.connection = connection
      let hostIdentity = ObjectIdentifier(viewController)
      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self, log] error in
          log.error("UI connection: \(error.localizedDescription)")
          let message = error.localizedDescription
          Task { @MainActor in
            guard let self, self.hostView.map(ObjectIdentifier.init) == hostIdentity,
              !self.ready, let window = self.window else { return }
            self.showLaunchFailure(message, in: window)
          }
        }) as? any ObeliskUIEndpoint
      else { throw RuntimeError.disconnected }
      let connectionIdentity = ObjectIdentifier(connection)
      let topInset = Double(hostView.windowTopInset)
      proxy.connect(topInset: topInset) {
        [weak self] message in
        Task { @MainActor in
          guard let self, self.connection.map(ObjectIdentifier.init) == connectionIdentity else {
            return
          }
          if let message {
            self.log.error("UI setup failed: \(message)")
            if let window = self.window { self.showLaunchFailure(message, in: window) }
            return
          }
          self.ready = true
          let events = self.pendingEvents
          self.pendingEvents.removeAll()
          for event in events { self.send(event) }
          if let window = self.window {
            window.ignoresMouseEvents = false
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
          }
          self.log.info("UI first frame ready and window presented with titlebar inset \(topInset, privacy: .public)")
        }
      }
    } catch {
      log.error("UI connection failed: \(error.localizedDescription)")
      if let window { showLaunchFailure(error.localizedDescription, in: window) }
    }
  }

  private func showLaunchFailure(_ message: String, in window: NSWindow) {
    guard self.window === window, window.attachedSheet == nil else { return }
    window.ignoresMouseEvents = false
    window.alphaValue = 1
    window.makeKeyAndOrderFront(nil)
    let alert = NSAlert()
    alert.messageText = "无法打开 Obelisk"
    alert.informativeText = message
    alert.beginSheetModal(for: window)
  }

  func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: (any Error)?)
  {
    guard viewController === hostView else { return }
    KeyboardShortcuts.isEnabled = true
    ready = false
    connection?.invalidate()
    connection = nil
    if let error { log.error("UI deactivated: \(error.localizedDescription)") }
  }

  func send(_ event: RuntimeEvent) {
    guard window != nil else { return }
    guard ready, let connection else {
      // Model and preference state are fetched on connection; only user commands must be queued
      if event.kind == .add || event.kind == .action { pendingEvents.append(event) }
      return
    }
    guard let data = try? RuntimeCoding.encode(event),
      let proxy = connection.remoteObjectProxy as? any ObeliskUIEndpoint
    else { return }
    proxy.receive(data)
  }

  func windowWillClose(_ notification: Notification) {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
    KeyboardShortcuts.isEnabled = true
    launchTask?.cancel()
    launchTask = nil
    let sessionID = UUID()
    let closing = ClosingUISession(
      window: window, host: hostView, connection: connection, process: extensionProcess
    ) { [weak self] in
      guard let self else { return }
      closingSessions.removeValue(forKey: sessionID)
      if closingSessions.isEmpty, window == nil {
        let completion = terminationCompletion
        terminationCompletion = nil
        completion?()
      }
    }
    closingSessions[sessionID] = closing
    window?.delegate = nil
    hostView?.delegate = nil
    ready = false
    window = nil
    sidebarTitlebarSpacer = nil
    NSApp.setActivationPolicy(.accessory)
    hostView = nil
    connection = nil
    extensionProcess = nil
    pendingEvents.removeAll()
    closing.close()
    log.info("UI session closing")
  }

  /// AppKit waits for the same preference flush used by an ordinary window close
  func prepareToTerminate(completion: @escaping () -> Void) -> Bool {
    guard window != nil || !closingSessions.isEmpty else { return false }
    terminationCompletion = completion
    window?.performClose(nil)
    return true
  }

  private func apply(_ state: RuntimeWindowState) {
    windowState = state
    sidebarTitlebarSpacer?.detailLeading = state.detailLeading
    window?.title = state.title
    window?.isOpaque = !state.transparent
    window?.backgroundColor = state.transparent ? .clear : .windowBackgroundColor
    window?.invalidateShadow()
    guard let toolbar = window?.toolbar else { return }
    let wanted: NSToolbarItem.Identifier? =
      state.showsTrash ? .emptyTrash : (state.canAdd ? .addBookmark : nil)
    if toolbar.items.last?.itemIdentifier != wanted {
      if toolbar.items.count > 2 { toolbar.removeItem(at: toolbar.items.count - 1) }
      if let wanted { toolbar.insertItem(withItemIdentifier: wanted, at: toolbar.items.count) }
    }
    for item in toolbar.items {
      if item.itemIdentifier == .addBookmark {
        item.isEnabled = state.canAdd
        item.toolTip = (state.addIsHidden ? "添加隐藏书签" : "添加书签").obeliskLocalized
      }
      if item.itemIdentifier == .emptyTrash { item.isEnabled = state.canEmptyTrash }
    }
  }
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.managerSidebar, .flexibleSpace, .addBookmark]
  }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.managerSidebar, .flexibleSpace, .addBookmark, .emptyTrash]
  }
  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard id != .flexibleSpace else { return nil }
    let item = NSToolbarItem(itemIdentifier: id)
    item.isNavigational = id == .managerSidebar
    item.autovalidates = false
    item.target = self
    item.action = #selector(toolbarAction(_:))
    item.label =
      (id == .managerSidebar ? "侧边栏" : id == .emptyTrash ? "清空废纸篓" : "添加").obeliskLocalized
    item.toolTip =
      (id == .managerSidebar ? "显示或隐藏侧边栏" : id == .emptyTrash ? "清空废纸篓" : "添加书签").obeliskLocalized
    item.image = NSImage(
      systemSymbolName: id == .managerSidebar
        ? "sidebar.left" : id == .emptyTrash ? "trash" : "plus",
      accessibilityDescription: item.label)
    if id == .emptyTrash {
      item.image = item.image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
    }
    return item
  }
  @objc private func toolbarAction(_ sender: NSToolbarItem) {
    send(
      RuntimeEvent(
        .action,
        value: sender.itemIdentifier == .managerSidebar
          ? "sidebar" : sender.itemIdentifier == .emptyTrash ? "emptyTrash" : "add"))
  }
  func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
    window.screen?.visibleFrame ?? newFrame
  }
  func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { true }
}
extension NSToolbarItem.Identifier {
  fileprivate static let managerSidebar = Self("ObeliskSidebar")
  fileprivate static let addBookmark = Self("ObeliskAddBookmark")
  fileprivate static let emptyTrash = Self("ObeliskEmptyTrash")
}

/// The split view lives in the UI process, so AppKit cannot discover its sidebar
/// when laying out the containing window's titlebar. Reserve that measured region
/// with a native leading accessory; AppKit still lays out the navigation item and title.
@MainActor
private final class SidebarTitlebarSpacer: NSTitlebarAccessoryViewController {
  var detailLeading: CGFloat = 0 {
    didSet { alignWithSidebar() }
  }

  init() {
    super.init(nibName: nil, bundle: nil)
    layoutAttribute = .leading
    view = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 1))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLayout() {
    super.viewDidLayout()
    alignWithSidebar()
  }

  private func alignWithSidebar() {
    guard view.window != nil else { return }
    let leading = view.convert(view.bounds, to: nil).minX
    let width = max(0, detailLeading - leading)
    guard abs(view.frame.width - width) > 0.25 else { return }
    view.setFrameSize(NSSize(width: width, height: view.frame.height))
  }
}

@MainActor
private final class BookmarkUIHostViewController: EXHostViewController {
  var onTopInsetChanged: ((CGFloat) -> Void)?
  private var previousTopInset: CGFloat?

  var windowTopInset: CGFloat {
    guard let window = view.window else { return 0 }
    let layoutRect = view.convert(window.contentLayoutRect, from: nil)
    return max(
      0,
      view.isFlipped
        ? layoutRect.minY - view.bounds.minY
        : view.bounds.maxY - layoutRect.maxY)
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    let inset = windowTopInset
    guard previousTopInset != inset else { return }
    previousTopInset = inset
    onTopInsetChanged?(inset)
  }
}

@MainActor
private final class ClosingUISession {
  private var window: NSWindow?
  private var host: EXHostViewController?
  private var connection: NSXPCConnection?
  private var process: AppExtensionProcess?
  private var completion: (() -> Void)?
  init(
    window: NSWindow?, host: EXHostViewController?, connection: NSXPCConnection?,
    process: AppExtensionProcess?, completion: @escaping () -> Void
  ) {
    self.window = window
    self.host = host
    self.connection = connection
    self.process = process
    self.completion = completion
  }
  func close() {
    guard let connection else {
      invalidate()
      return
    }
    guard
      let proxy = connection.remoteObjectProxyWithErrorHandler({ [self] _ in
        Task { @MainActor in invalidate() }
      }) as? any ObeliskUIEndpoint
    else {
      invalidate()
      return
    }
    proxy.shutdown { [self] in Task { @MainActor in invalidate() } }
  }
  private func invalidate() {
    connection?.invalidate()
    connection = nil
    host?.configuration = nil
    host = nil
    window?.contentViewController = nil
    window = nil
    process?.invalidate()
    process = nil
    let completion = completion
    self.completion = nil
    completion?()
    Logger(subsystem: "com.eli.Obelisk", category: "WindowRuntime").info("UI session released")
  }
}
