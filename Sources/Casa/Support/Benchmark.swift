import AppKit

/// Drives navigation automatically and reports how long each step took to
/// reach the screen.
///
/// Trait 01 is usually discussed as cold launch, but cold launch happens once
/// and navigation happens hundreds of times. This measures the number that
/// actually decides whether the app feels like Picasa: the gap between
/// pressing an arrow key and seeing the next photograph.
///
/// Enabled with `--bench <steps>`; absent from normal runs.
@MainActor
final class Benchmark {

    private let steps: Int
    private var remaining: Int
    private var startOfStep = ContinuousClock.now
    private var firstPaintTimes: [Double] = []
    private var sharpTimes: [Double] = []
    private var sawFirstPaintThisStep = false
    private let advance: () -> Void

    init?(arguments: [String], advance: @escaping () -> Void) {
        guard let flag = arguments.firstIndex(of: "--bench"),
              arguments.indices.contains(flag + 1),
              let steps = Int(arguments[flag + 1]), steps > 0
        else { return nil }
        self.steps = steps
        self.remaining = steps
        self.advance = advance
    }

    /// Called once the opening image is fully sharp, so the run measures
    /// steady-state navigation rather than launch.
    func begin() {
        Log.launch.notice("benchmark: \(self.steps, privacy: .public) steps")
        nextStep()
    }

    /// Called for every rung that reaches the screen, and once with `nil` when
    /// a file could not be displayed at all.
    func recordPaint(tier: DecodeTier?) {
        let elapsed = startOfStep.duration(to: .now).seconds * 1000

        guard let tier else {
            // An unreadable file is a completed step, not a hang. Its timings
            // are excluded so a folder containing junk does not flatter the
            // averages.
            unreadable += 1
            nextStep()
            return
        }

        if !sawFirstPaintThisStep {
            sawFirstPaintThisStep = true
            firstPaintTimes.append(elapsed)
        }

        // `display` or better means the image is final; the step is done.
        guard tier >= .display else { return }
        sharpTimes.append(elapsed)
        nextStep()
    }

    private var unreadable = 0

    private func nextStep() {
        guard remaining > 0 else { return report() }
        remaining -= 1
        sawFirstPaintThisStep = false
        // One runloop turn between steps, so each measurement starts from a
        // settled state rather than overlapping the previous one.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startOfStep = .now
            self.stepToken += 1
            let token = self.stepToken
            self.advance()

            // A step that never paints would hang the run silently. Report
            // what we have rather than leaving someone staring at a window
            // wondering whether it is still working.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.stepToken == token else { return }
                Log.launch.error("benchmark: step timed out, reporting early")
                self.remaining = 0
                self.report()
            }
        }
    }

    private var stepToken = 0

    private func report() {
        func summarize(_ label: String, _ samples: [Double]) {
            guard !samples.isEmpty else { return }
            let sorted = samples.sorted()
            let median = sorted[sorted.count / 2]
            let worst = sorted.last ?? 0
            let mean = samples.reduce(0, +) / Double(samples.count)
            Log.launch.notice("""
                benchmark \(label, privacy: .public): \
                median \(String(format: "%.1f", median), privacy: .public)ms \
                mean \(String(format: "%.1f", mean), privacy: .public)ms \
                worst \(String(format: "%.1f", worst), privacy: .public)ms \
                n=\(samples.count, privacy: .public)
                """)
        }
        summarize("first-pixels", firstPaintTimes)
        summarize("sharp", sharpTimes)
        if unreadable > 0 {
            Log.launch.notice("benchmark: \(self.unreadable, privacy: .public) unreadable files skipped")
        }
        Log.launch.notice("benchmark: complete")
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
