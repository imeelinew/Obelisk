import AppKit
import Sparkle

@objc
private protocol StandardMenuActionSelectors {
    func print(_ sender: Any?)
    func setSearchString(_ sender: Any?)
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

/// Standard macOS commands use the responder chain; application commands target the delegate.
@MainActor
enum ApplicationMenu {
    static func install(
        updaterController: SPUStandardUpdaterController,
        target: AnyObject,
        openManager: Selector,
        newBookmark: Selector
    ) {
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
        let settingsItem = NSMenuItem(title: NSLocalizedString("Settings…", comment: "App menu"), action: openManager, keyEquivalent: ",")
        settingsItem.target = target
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
        let newItem = NSMenuItem(title: NSLocalizedString("New Bookmark", comment: "File menu"), action: newBookmark, keyEquivalent: "n")
        newItem.target = target
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

}
