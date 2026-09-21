import Foundation

/// Downloads a release archive, reporting progress as it goes.
///
/// Streams to disk in chunks rather than using `URLSession.download`, purely so
/// progress is available: a determinate bar with real byte counts is most of
/// what makes an update feel considered instead of frozen.
struct UpdateDownloader: Sendable {

    struct Progress: Sendable {
        let received: Int64
        let expected: Int64
        /// Bytes per second, averaged over the whole transfer.
        let bytesPerSecond: Double

        var fraction: Double {
            expected > 0 ? min(1, Double(received) / Double(expected)) : 0
        }

        var remaining: TimeInterval? {
            guard bytesPerSecond > 0, expected > received else { return nil }
            return Double(expected - received) / bytesPerSecond
        }
    }

    /// Where downloads live. Caches, not Application Support: a half-finished
    /// update is not something the user needs backed up or preserved.
    static func stagingDirectory() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let directory = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.jackharvest.casa")
            .appendingPathComponent("Updates")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Downloads `release`'s archive and returns the local file.
    ///
    /// `onProgress` is called on an arbitrary executor; the caller hops to the
    /// main actor.
    func download(_ release: UpdateRelease,
                  onProgress: @escaping @Sendable (Progress) -> Void) async throws -> URL {
        let directory = try Self.stagingDirectory()
        let destination = directory.appendingPathComponent(release.archiveURL.lastPathComponent)
        // Any previous attempt is worthless; a resumed partial download of a
        // file we verify by digest anyway buys nothing.
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var request = URLRequest(url: release.archiveURL)
        request.timeoutInterval = 60
        request.setValue("Casa", forHTTPHeaderField: "User-Agent")

        let (stream, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateChecker.Failure.badResponse(http.statusCode)
        }

        let expected = response.expectedContentLength > 0
            ? response.expectedContentLength
            : release.archiveBytes
        let started = ContinuousClock.now

        var buffer = Data()
        buffer.reserveCapacity(1 << 18)
        var received: Int64 = 0
        var lastReport = ContinuousClock.now

        for try await byte in stream {
            buffer.append(byte)
            if buffer.count >= 1 << 18 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                // Throttled to ~20 Hz. Reporting per chunk would spend more
                // time updating a progress bar than moving bytes.
                if lastReport.duration(to: .now) > .milliseconds(50) {
                    lastReport = .now
                    let seconds = started.duration(to: .now).seconds
                    onProgress(Progress(received: received, expected: expected,
                                        bytesPerSecond: seconds > 0 ? Double(received) / seconds : 0))
                }
            }
            try Task.checkCancellation()
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        let seconds = started.duration(to: .now).seconds
        onProgress(Progress(received: received, expected: max(expected, received),
                            bytesPerSecond: seconds > 0 ? Double(received) / seconds : 0))

        Log.update.info("downloaded \(received, privacy: .public) bytes in \(String(format: "%.1f", seconds), privacy: .public)s")
        return destination
    }
}
