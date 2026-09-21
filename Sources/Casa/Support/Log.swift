import os

/// Subsystem-wide logging. Categories map to the layers in `docs/architecture.md`.
///
/// `os.Logger` is effectively free when no one is collecting — messages are not
/// formatted unless a consumer attaches — so these can stay on the hot path.
enum Log {
    private static let subsystem = "com.jackharvest.casa"

    static let launch = Logger(subsystem: subsystem, category: "launch")
    static let decode = Logger(subsystem: subsystem, category: "decode")
    static let folder = Logger(subsystem: subsystem, category: "folder")
    static let render = Logger(subsystem: subsystem, category: "render")
}
