// Covers the main display with a wallpaper, so README screen recordings show a
// neutral desktop instead of whatever is really open. Casa opens on top of it.
//
// usage: Backdrop <image>      (kill it when done)
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens[0]
let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.level = .normal
let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
view.image = NSImage(contentsOfFile: CommandLine.arguments[1])
view.imageScaling = .scaleAxesIndependently
window.contentView = view
window.setFrame(screen.frame, display: true)
window.orderFrontRegardless()
app.run()
