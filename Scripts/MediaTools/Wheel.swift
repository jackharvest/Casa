// usage: Wheel <x> <y> <ticks> <interval> [direction]
//
// Moves the pointer to (x, y) in global top-left coordinates and sends
// mouse-wheel line ticks — a real wheel, not a trackpad.
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let point = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
let ticks = Int(a[3])!, interval = Double(a[4])!
let direction: Int32 = a.count > 5 ? Int32(a[5])! : 1
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(300_000)
for _ in 0..<ticks {
    CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: direction, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    usleep(useconds_t(interval * 1_000_000))
}
