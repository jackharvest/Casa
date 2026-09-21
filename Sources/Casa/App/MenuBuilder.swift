import AppKit

/// A minimal menu bar.
///
/// Picasa's viewer had no menus at all, but on macOS the menu bar is where
/// standard shortcuts are *registered*, not merely advertised — without these
/// items ⌘Q and ⌘W do not work, and the app reads as broken to anyone who
/// reaches for them. Every item here earns its place by carrying a shortcut
/// the platform has taught people to expect.
@MainActor
enum MenuBuilder {

    static func install() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = appMenu()
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        editItem.submenu = editMenu()
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        viewItem.submenu = viewMenu()
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        add(to: menu, "About \(name)", #selector(AppDelegate.showAbout(_:)), "", [])
        add(to: menu, "Welcome to \(name)", #selector(AppDelegate.showWelcome(_:)), "", [])
        menu.addItem(.separator())
        add(to: menu, "Check for Updates\u{2026}", #selector(AppDelegate.checkForUpdates(_:)), "", [])
        add(to: menu, "Check Automatically", #selector(AppDelegate.toggleAutomaticUpdates(_:)), "", [])
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        add(to: menu, "Copy Image", #selector(ViewerController.copyImage(_:)), "c", [.command])
        add(to: menu, "Copy Path", #selector(ViewerController.copyPath(_:)), "c", [.command, .option])
        menu.addItem(.separator())
        add(to: menu, "Reveal in Finder", #selector(ViewerController.revealInFinder(_:)), "r", [.command])
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")

        add(to: menu, "Next Image", #selector(ViewerController.goNext(_:)), "]", [.command])
        add(to: menu, "Previous Image", #selector(ViewerController.goPrevious(_:)), "[", [.command])
        menu.addItem(.separator())
        add(to: menu, "Fit to Window", #selector(ViewerController.zoomToFit(_:)), "0", [.command])
        add(to: menu, "Actual Size", #selector(ViewerController.zoomToActual(_:)), "1", [.command])
        menu.addItem(.separator())
        add(to: menu, "Rotate Left", #selector(ViewerController.rotateLeft(_:)), "[", [.command, .shift])
        add(to: menu, "Rotate Right", #selector(ViewerController.rotateRight(_:)), "]", [.command, .shift])
        menu.addItem(.separator())
        add(to: menu, "Play", #selector(ViewerController.togglePlayback(_:)), " ", [])

        let playbackItem = NSMenuItem(title: "Playback", action: nil, keyEquivalent: "")
        let playbackMenu = NSMenu(title: "Playback")
        for policy in PlaybackPolicy.allCases {
            let item = NSMenuItem(title: policy.title,
                                  action: #selector(ViewerController.setPlaybackPolicy(_:)),
                                  keyEquivalent: "")
            item.representedObject = policy.rawValue
            playbackMenu.addItem(item)
        }
        playbackItem.submenu = playbackMenu
        menu.addItem(playbackItem)

        menu.addItem(.separator())
        add(to: menu, "Use Finder’s Sort Order", #selector(ViewerController.toggleFinderSort(_:)), "", [])
        add(to: menu, "Hide Dock for Larger Preview", #selector(ViewerController.toggleHidesDock(_:)), "d", [.command, .shift])

        return menu
    }

    private static func add(to menu: NSMenu,
                            _ title: String,
                            _ action: Selector,
                            _ key: String,
                            _ modifiers: NSEvent.ModifierFlags) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        // No explicit target: the responder chain resolves it, so the item
        // dims automatically when no viewer is frontmost.
        menu.addItem(item)
    }
}
