import AppKit
import PDFKit

/// The menu bar.
///
/// Picasa's viewer had no menus at all, but on macOS the menu bar is where
/// standard shortcuts are *registered*, not merely advertised — without these
/// items ⌘Q and ⌘W do not work, and the app reads as broken to anyone who
/// reaches for them. It is also where everything the floating chrome has no
/// room for lives: the chrome stays a handful of buttons because the full
/// list is here, in the places Preview taught people to look.
@MainActor
enum MenuBuilder {

    static func install() {
        let mainMenu = NSMenu()
        for menu in [appMenu(), fileMenu(), editMenu(), viewMenu(), goMenu(), toolsMenu(), windowMenu()] {
            let item = NSMenuItem()
            item.submenu = menu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        add(to: menu, "About \(name)", #selector(AppDelegate.showAbout(_:)))
        add(to: menu, "Welcome to \(name)", #selector(AppDelegate.showWelcome(_:)))
        menu.addItem(.separator())
        add(to: menu, "Check for Updates\u{2026}", #selector(AppDelegate.checkForUpdates(_:)))
        add(to: menu, "Check Automatically", #selector(AppDelegate.toggleAutomaticUpdates(_:)))
        menu.addItem(.separator())
        add(to: menu, "Hide \(name)", #selector(NSApplication.hide(_:)), "h")
        add(to: menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(to: menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(to: menu, "Quit \(name)", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        add(to: menu, "Open\u{2026}", #selector(AppDelegate.openDocument(_:)), "o")
        menu.addItem(submenu("Open Recent", delegate: RecentMenu.shared))
        add(to: menu, "New from Clipboard", #selector(AppDelegate.newFromClipboard(_:)), "n")
        menu.addItem(.separator())
        add(to: menu, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(to: menu, "Save", #selector(ViewerController.save(_:)), "s")
        add(to: menu, "Duplicate", #selector(ViewerController.duplicateFile(_:)), "s", [.command, .shift])
        add(to: menu, "Rename\u{2026}", #selector(ViewerController.renameFile(_:)))
        add(to: menu, "Revert to Saved", #selector(ViewerController.revertToSaved(_:)))
        add(to: menu, "Move to Trash", #selector(ViewerController.moveToTrash(_:)), "\u{8}")
        menu.addItem(.separator())
        add(to: menu, "Export\u{2026}", #selector(ViewerController.exportDocument(_:)), "e", [.command, .shift])
        add(to: menu, "Share\u{2026}", #selector(ViewerController.share(_:)))
        menu.addItem(submenu("Open With", delegate: OpenWithMenu.shared))
        add(to: menu, "Reveal in Finder", #selector(ViewerController.revealInFinder(_:)), "r")
        add(to: menu, "Set as Desktop Picture", #selector(ViewerController.setDesktopPicture(_:)))
        menu.addItem(.separator())
        add(to: menu, "Print\u{2026}", #selector(ViewerController.printDocument(_:)), "p")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // The standard selectors, so the window's undo manager titles and
        // enables these itself: "Undo Crop", "Redo Move to Trash".
        add(to: menu, "Undo", Selector(("undo:")), "z")
        add(to: menu, "Redo", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        // `copy:` rather than a selector of our own, so that text selected in
        // a document, or typed into the search field, copies as text.
        add(to: menu, "Copy", #selector(ViewerController.copy(_:)), "c")
        add(to: menu, "Copy Path", #selector(ViewerController.copyPath(_:)), "c", [.command, .option])
        add(to: menu, "Paste", #selector(NSText.paste(_:)), "v")
        add(to: menu, "Select All", #selector(NSResponder.selectAll(_:)), "a")
        menu.addItem(.separator())
        add(to: menu, "Find\u{2026}", #selector(ViewerController.find(_:)), "f")
        add(to: menu, "Find Next", #selector(ViewerController.findNext(_:)), "g")
        add(to: menu, "Find Previous", #selector(ViewerController.findPrevious(_:)), "g", [.command, .shift])
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")

        add(to: menu, "Fit to Window", #selector(ViewerController.zoomToFit(_:)), "0")
        add(to: menu, "Actual Size", #selector(ViewerController.zoomToActual(_:)), "1")
        add(to: menu, "Zoom In", #selector(ViewerController.zoomIn(_:)), "+")
        add(to: menu, "Zoom Out", #selector(ViewerController.zoomOut(_:)), "-")
        menu.addItem(.separator())
        add(to: menu, "Show Inspector", #selector(ViewerController.toggleInspector(_:)), "i")
        add(to: menu, "Show Sidebar", #selector(ViewerController.toggleSidebar(_:)), "s", [.command, .option])
        for (title, mode) in [("Single Page", PDFDisplayMode.singlePage),
                              ("Continuous Scroll", .singlePageContinuous),
                              ("Two Pages", .twoUpContinuous)] {
            let item = add(to: menu, title, #selector(ViewerController.setPageLayout(_:)))
            item.tag = mode.rawValue
        }
        menu.addItem(.separator())
        add(to: menu, "Start Slideshow", #selector(ViewerController.toggleSlideshow(_:)))
        add(to: menu, "Play", #selector(ViewerController.togglePlayback(_:)), " ", [])

        let playbackMenu = NSMenu(title: "Playback")
        for policy in PlaybackPolicy.allCases {
            let item = add(to: playbackMenu, policy.title, #selector(ViewerController.setPlaybackPolicy(_:)))
            item.representedObject = policy.rawValue
        }
        let playbackItem = NSMenuItem(title: "Playback", action: nil, keyEquivalent: "")
        playbackItem.submenu = playbackMenu
        menu.addItem(playbackItem)

        menu.addItem(.separator())
        add(to: menu, "Use Finder’s Sort Order", #selector(ViewerController.toggleFinderSort(_:)))
        add(to: menu, "Hide Dock for Larger Preview", #selector(ViewerController.toggleHidesDock(_:)), "d", [.command, .shift])
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        add(to: menu, "Next", #selector(ViewerController.goNextFile(_:)), "]")
        add(to: menu, "Previous", #selector(ViewerController.goPreviousFile(_:)), "[")
        menu.addItem(.separator())
        add(to: menu, "Go to Page\u{2026}", #selector(ViewerController.goToPage(_:)), "g", [.command, .option])
        add(to: menu, "First Page", #selector(ViewerController.goToFirstPage(_:)))
        add(to: menu, "Last Page", #selector(ViewerController.goToLastPage(_:)))
        return menu
    }

    private static func toolsMenu() -> NSMenu {
        let menu = NSMenu(title: "Tools")
        addEditingItems(to: menu, withShortcuts: true)
        menu.addItem(.separator())
        add(to: menu, "Highlight", #selector(ViewerController.highlightSelection(_:)), "h", [.command, .control])
        add(to: menu, "Underline", #selector(ViewerController.underlineSelection(_:)), "u", [.command, .control])
        add(to: menu, "Strike Through", #selector(ViewerController.strikeThroughSelection(_:)), "s", [.command, .control])
        menu.addItem(.separator())
        add(to: menu, "Insert Pages from File\u{2026}", #selector(ViewerController.insertPagesFromFile(_:)))
        add(to: menu, "Insert Blank Page", #selector(ViewerController.insertBlankPage(_:)))
        add(to: menu, "Delete Page", #selector(ViewerController.deletePage(_:)))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        add(to: menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(to: menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = menu
        return menu
    }

    /// The tools that change a picture, in one order everywhere they appear.
    private static func addEditingItems(to menu: NSMenu, withShortcuts: Bool) {
        func key(_ key: String) -> String { withShortcuts ? key : "" }
        add(to: menu, "Show Markup Tools", #selector(ViewerController.toggleMarkup(_:)), key("a"), [.command, .shift])
        add(to: menu, "Crop", #selector(ViewerController.crop(_:)), key("k"))
        add(to: menu, "Adjust Color\u{2026}", #selector(ViewerController.adjustColor(_:)), key("a"), [.command, .option])
        add(to: menu, "Adjust Size\u{2026}", #selector(ViewerController.adjustSize(_:)))
        add(to: menu, "Remove Background", #selector(ViewerController.removeBackground(_:)), key("k"), [.command, .shift])
        menu.addItem(.separator())
        add(to: menu, "Rotate Left", #selector(ViewerController.rotateLeft(_:)), key("["), [.command, .shift])
        add(to: menu, "Rotate Right", #selector(ViewerController.rotateRight(_:)), key("]"), [.command, .shift])
        add(to: menu, "Flip Horizontal", #selector(ViewerController.flipHorizontal(_:)))
        add(to: menu, "Flip Vertical", #selector(ViewerController.flipVertical(_:)))
    }

    /// The right-click menu, and the toolbar's "more" button: everything
    /// that can be done to the file on screen, without the shortcuts, which
    /// AppKit would otherwise register a second time.
    static func contextMenu() -> NSMenu {
        let menu = NSMenu()
        addEditingItems(to: menu, withShortcuts: false)
        menu.addItem(.separator())
        add(to: menu, "Copy", #selector(ViewerController.copyImage(_:)))
        add(to: menu, "Copy Path", #selector(ViewerController.copyPath(_:)))
        add(to: menu, "Share\u{2026}", #selector(ViewerController.share(_:)))
        add(to: menu, "Export\u{2026}", #selector(ViewerController.exportDocument(_:)))
        add(to: menu, "Print\u{2026}", #selector(ViewerController.printDocument(_:)))
        menu.addItem(.separator())
        add(to: menu, "Rename\u{2026}", #selector(ViewerController.renameFile(_:)))
        add(to: menu, "Duplicate", #selector(ViewerController.duplicateFile(_:)))
        add(to: menu, "Move to Trash", #selector(ViewerController.moveToTrash(_:)))
        menu.addItem(.separator())
        add(to: menu, "Reveal in Finder", #selector(ViewerController.revealInFinder(_:)))
        menu.addItem(submenu("Open With", delegate: OpenWithMenu.shared))
        add(to: menu, "Set as Desktop Picture", #selector(ViewerController.setDesktopPicture(_:)))
        add(to: menu, "Show Inspector", #selector(ViewerController.toggleInspector(_:)))
        return menu
    }

    private static func submenu(_ title: String, delegate: NSMenuDelegate) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = delegate
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(to menu: NSMenu,
                            _ title: String,
                            _ action: Selector,
                            _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        // No explicit target: the responder chain resolves it, so the item
        // dims automatically when no viewer is frontmost.
        menu.addItem(item)
        return item
    }
}

/// Fills File › Open Recent each time it opens.
///
/// The list is the system's own — the same one the Dock icon's menu shows —
/// so there is no history of ours to keep or to leak.
@MainActor
final class RecentMenu: NSObject, NSMenuDelegate {

    static let shared = RecentMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recents = NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        for url in recents.prefix(12) {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(AppDelegate.openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !recents.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu",
                               action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = NSDocumentController.shared
        clear.isEnabled = !recents.isEmpty
        menu.addItem(clear)
    }
}

/// Fills Open With from whatever else on this Mac can open the current file.
@MainActor
final class OpenWithMenu: NSObject, NSMenuDelegate {

    static let shared = OpenWithMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = NSApp.keyWindow?.contentViewController as? ViewerController
            ?? NSApp.mainWindow?.contentViewController as? ViewerController
        guard let url = controller?.currentFile else {
            menu.addItem(withTitle: "No File", action: nil, keyEquivalent: "")
            return
        }

        let ours = Bundle.main.bundleURL.standardizedFileURL
        let applications = NSWorkspace.shared.urlsForApplications(toOpen: url)
            .filter { $0.standardizedFileURL != ours }

        for application in applications.prefix(16) {
            let name = FileManager.default.displayName(atPath: application.path)
                .replacingOccurrences(of: ".app", with: "")
            let item = NSMenuItem(title: name, action: #selector(ViewerController.openWith(_:)), keyEquivalent: "")
            item.representedObject = application
            let icon = NSWorkspace.shared.icon(forFile: application.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if applications.isEmpty {
            menu.addItem(withTitle: "No Other Apps", action: nil, keyEquivalent: "")
        }
    }
}
