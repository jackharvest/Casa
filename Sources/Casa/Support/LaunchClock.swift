import Foundation
import os

/// Trait 01 is a *measured* budget, not an aspiration: double-click to
/// photo-on-screen in under 100 ms. This records the milestones along that path
/// so a regression shows up as a number instead of a vibe.
///
/// `mach_absolute_time` is captured as early as the process can reach — see
/// `main.swift`, which touches `LaunchClock.processStart` before anything else.
enum LaunchClock {
    /// Captured on first access. `main.swift` forces that to happen at the top
    /// of the process so the reading is as close to exec as we can get.
    static let processStart = ContinuousClock.now

    private nonisolated(unsafe) static var recorded: [(String, Duration)] = []
    private static let lock = OSAllocatedUnfairLock()

    /// Stamps a named milestone relative to process start.
    static func mark(_ milestone: String) {
        let elapsed = LaunchClock.processStart.duration(to: .now)
        lock.lock()
        recorded.append((milestone, elapsed))
        lock.unlock()
        Log.launch.info("\(milestone, privacy: .public) +\(elapsed.milliseconds, privacy: .public)ms")
    }

    /// Human-readable summary, emitted once the first frame is on screen.
    static func summary() -> String {
        lock.lock()
        let snapshot = recorded
        lock.unlock()
        return snapshot
            .map { "\($0.0) \($0.1.milliseconds)ms" }
            .joined(separator: "  ·  ")
    }
}

extension Duration {
    /// Milliseconds to one decimal place, for logging.
    var milliseconds: String {
        let ns = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        return String(format: "%.1f", Double(ns) / 1_000_000)
    }
}
