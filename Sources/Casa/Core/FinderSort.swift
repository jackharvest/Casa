import AppKit
import ApplicationServices

/// Reads the sort order of the Finder window a file was opened from.
///
/// This is trait 07, and the reason it is worth the trouble: no macOS viewer
/// does it. If you have sorted a folder by date added and open the third photo,
/// every other viewer will walk it alphabetically — quietly wrong, every time.
///
/// **What Finder will and will not tell us**, verified against macOS 26:
///
/// | View | Exposed |
/// |---|---|
/// | List | `sort column` and its `sort direction` |
/// | Icon | `arrangement` |
/// | Column | nothing — `column view options` has no sort property |
/// | Gallery (`flow view`) | nothing — no options class exists |
///
/// So two of the four view modes answer, and the other two fall back to name
/// ordering, which is also what Finder itself defaults to there. Partial
/// coverage that degrades to the sensible default is worth shipping; pretending
/// to coverage we do not have is not.
enum FinderSort {

    struct Result: Sendable, Equatable {
        let order: SortOrder
        let ascending: Bool
    }

    // MARK: - Permission

    enum Permission {
        /// We may send Apple Events to Finder.
        case granted
        /// The user has said no. Respect it and never ask again.
        case denied
        /// Never asked. Asking shows a system dialog, so it happens only on a
        /// deliberate user action, never during launch.
        case notDetermined
        /// Finder is not running, or something else went wrong.
        case unavailable
    }

    /// Checks whether we are allowed to automate Finder **without prompting**.
    ///
    /// The distinction matters: the prompt is modal and blocks until answered.
    /// Triggering it from the launch path would freeze a window whose entire
    /// selling point is that it appears instantly.
    static func permission(askingIfNeeded: Bool = false) -> Permission {
        guard let target = NSAppleEventDescriptor(
            descriptorType: typeApplicationBundleID,
            data: Data(finderBundleIdentifier.utf8)
        ) else { return .unavailable }

        guard let status = target.withAEDesc({ descriptor -> OSStatus in
            AEDeterminePermissionToAutomateTarget(
                descriptor, typeWildCard, typeWildCard, askingIfNeeded
            )
        }) else { return .unavailable }

        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unavailable
        }
    }

    // MARK: - Reading

    /// Sort order of the Finder window showing `directory`, or nil if there
    /// isn't one, the view mode doesn't expose it, or we lack permission.
    ///
    /// Returns nil freely. Every caller has a correct fallback, so guessing
    /// would be strictly worse than declining to answer.
    ///
    /// Runs off the main thread. The *first* Apple Event a process sends costs
    /// roughly 350 ms — compiling the script, and establishing the connection
    /// to Finder — even though subsequent ones are too cheap to measure. On
    /// the main thread that lands directly in front of the first paint, which
    /// measured as a 537 ms → 894 ms regression. Nothing about reading a sort
    /// order is worth a third of a second of blank window.
    static func order(forDirectory directory: URL) async -> Result? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: orderSynchronously(forDirectory: directory))
            }
        }
    }

    /// Serial, and private. `NSAppleScript` is not thread-safe, so every use of
    /// it in this process happens here and nowhere else — one thread, one at a
    /// time, which is the condition under which it behaves.
    private static let queue = DispatchQueue(label: "com.jackharvest.finder-sort", qos: .utility)

    private static func orderSynchronously(forDirectory directory: URL) -> Result? {
        guard permission() == .granted else { return nil }

        guard let output = runScript() else { return nil }
        let wanted = directory.resolvingSymlinksInPath().standardizedFileURL.path

        for line in output.components(separatedBy: "\n") {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 4 else { continue }

            // Finder reports `/private/tmp/...` where the URL may say `/tmp/...`,
            // and appends a trailing slash to directories.
            let reported = URL(fileURLWithPath: fields[0])
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard reported == wanted else { continue }

            return interpret(view: fields[1], column: fields[2], direction: fields[3])
        }
        return nil
    }

    private static func interpret(view: String, column: String, direction: String) -> Result? {
        let ascending = !direction.contains("reversed")

        if view.contains("list") {
            guard let order = orderFromColumnName(column) else { return nil }
            return Result(order: order, ascending: ascending)
        }

        if view.contains("icon") {
            // "not arranged" and "snap to grid" carry no ordering.
            guard column.contains("arranged by"),
                  let order = orderFromColumnName(column) else { return nil }
            return Result(order: order, ascending: true)
        }

        // Column and gallery views expose nothing.
        return nil
    }

    private static func orderFromColumnName(_ raw: String) -> SortOrder? {
        if raw.contains("modification date") { return .dateModified }
        if raw.contains("creation date") { return .dateCreated }
        if raw.contains("size") { return .size }
        if raw.contains("name") { return .name }
        return nil
    }

    // MARK: - Script

    /// One round trip returning every Finder window, rather than one per
    /// window: the Apple Events themselves measured as effectively free, but
    /// each `NSAppleScript` execution is not, so the loop belongs on Finder's
    /// side of the boundary.
    private static let source = """
    tell application "Finder"
        set out to ""
        repeat with i from 1 to (count of Finder windows)
            set w to Finder window i
            try
                set p to POSIX path of (target of w as alias)
                set v to (current view of w) as text
                set col to "?"
                set dir to "normal"
                if v contains "list" then
                    set sc to sort column of (list view options of w)
                    set col to (name of sc) as text
                    set dir to (sort direction of sc) as text
                else if v contains "icon" then
                    set col to (arrangement of (icon view options of w)) as text
                end if
                set out to out & p & tab & v & tab & col & tab & dir & linefeed
            end try
        end repeat
        return out
    end tell
    """

    /// Compiled once. Compilation is the expensive part; execution is not.
    private nonisolated(unsafe) static let compiled: NSAppleScript? = NSAppleScript(source: source)

    private static func runScript() -> String? {
        dispatchPrecondition(condition: .onQueue(queue))

        var error: NSDictionary?
        let result = compiled?.executeAndReturnError(&error)
        if let error {
            Log.folder.error("Finder sort query failed: \(error, privacy: .public)")
            return nil
        }
        return result?.stringValue
    }

    private static func report(_ message: String) {
        print(message)
        Log.folder.notice("probe: \(message, privacy: .public)")
    }

    private static let finderBundleIdentifier = "com.apple.finder"

    // MARK: - Probe

    /// Diagnostic entry point: `--finder-sort-probe <folder>`.
    ///
    /// Trait 07 cannot be verified without a human approving a consent dialog,
    /// so this makes that a single command rather than a hunt through menus.
    ///
    /// **Run it via `open -a`, not by executing the binary.** TCC attributes
    /// Automation consent to the *responsible process*, so a build launched
    /// from a terminal silently inherits the terminal's existing permission
    /// to control Finder and reports `granted` when the app itself has no such
    /// right. Launched the way a user launches it, the app is its own
    /// responsible process and the answer is truthful.
    ///
    /// Results go to the unified log as well as stdout, because `open` does
    /// not give us a stdout to write to.
    static func runProbe(directory: URL) -> Never {
        let state = queue.sync { permission(askingIfNeeded: true) }
        report("permission: \(state)")

        guard state == .granted else {
            report("result: unavailable - approve the dialog, or check System Settings > Privacy & Security > Automation")
            exit(1)
        }

        report("raw: " + (queue.sync { runScript() }?.replacingOccurrences(of: "\n", with: " | ") ?? "<no output>"))

        report("looking for: \(directory.resolvingSymlinksInPath().standardizedFileURL.path)")
        if let result = queue.sync(execute: { orderSynchronously(forDirectory: directory) }) {
            report("result: \(result.order.rawValue) ascending=\(result.ascending)")
        } else {
            report("result: nil - no matching window, or this view mode exposes no sort")
        }
        exit(0)
    }
}

private extension NSAppleEventDescriptor {
    /// Bridges to the `AEAddressDesc` pointer the permission API requires.
    /// Returns nil rather than force-unwrapping — a descriptor without a
    /// backing `AEDesc` is unusual but not worth crashing over.
    func withAEDesc<T>(_ body: (UnsafePointer<AEAddressDesc>) -> T) -> T? {
        guard let descriptor = aeDesc else { return nil }
        return withUnsafePointer(to: descriptor.pointee) { body($0) }
    }
}
