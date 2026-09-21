// Prints on-screen window ids and bounds for an app, so captures can target a
// window exactly instead of guessing crop offsets.
//
// usage: WindowList <owner-name>      -> "<id> <x> <y> <w> <h> <title>"
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { exit(1) }

for window in windows {
    let name = window[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.isEmpty || name == owner else { continue }
    guard let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
          let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double
    else { continue }
    let title = window[kCGWindowName as String] as? String ?? ""
    print("\(id) \(Int(x)) \(Int(y)) \(Int(w)) \(Int(h)) \(name) | \(title)")
}
