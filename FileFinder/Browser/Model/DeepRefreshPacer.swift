import Foundation

/// Decides when a folder that changed deep inside may be walked again.
///
/// The pause after a walk is the longer of `baseInterval` and `walkMultiplier` times that walk's
/// duration, counted from when it ended. A huge, constantly changing tree (like ~/Library) is
/// therefore walked at most a fraction of the time instead of back to back.
nonisolated struct DeepRefreshPacer: Sendable {
    var baseInterval: Duration
    var walkMultiplier = 2

    private var lastWalks: [URL: (ended: ContinuousClock.Instant, duration: Duration)] = [:]

    init(baseInterval: Duration) {
        self.baseInterval = baseInterval
    }

    func isDue(_ folder: URL, at now: ContinuousClock.Instant) -> Bool {
        guard let walk = lastWalks[folder] else { return true }
        return now - walk.ended >= max(baseInterval, walk.duration * walkMultiplier)
    }

    mutating func recordWalk(of folder: URL, started: ContinuousClock.Instant, ended: ContinuousClock.Instant) {
        lastWalks[folder] = (ended, ended - started)
    }

    mutating func reset() {
        lastWalks = [:]
    }
}
