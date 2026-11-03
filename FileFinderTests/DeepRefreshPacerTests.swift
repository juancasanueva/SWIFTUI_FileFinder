import Foundation
import Testing
@testable import FileFinder

@Suite("Deep refresh pacing")
struct DeepRefreshPacerTests {
    let folder = URL(filePath: "/Users/me/Library")
    let start = ContinuousClock.now

    @Test("A folder that was never walked is due right away")
    func neverWalkedIsDue() {
        let pacer = DeepRefreshPacer(baseInterval: .seconds(10))
        #expect(pacer.isDue(folder, at: start))
    }

    @Test("After a quick walk, the folder waits the base interval")
    func quickWalkWaitsBaseInterval() {
        var pacer = DeepRefreshPacer(baseInterval: .seconds(10))
        pacer.recordWalk(of: folder, started: start, ended: start + .seconds(1))

        #expect(!pacer.isDue(folder, at: start + .seconds(10)))
        #expect(pacer.isDue(folder, at: start + .seconds(11)))
    }

    @Test("After a long walk, the pause grows to twice the walk's duration")
    func longWalkWaitsLonger() {
        var pacer = DeepRefreshPacer(baseInterval: .seconds(10))
        pacer.recordWalk(of: folder, started: start, ended: start + .seconds(60))

        #expect(!pacer.isDue(folder, at: start + .seconds(60 + 119)))
        #expect(pacer.isDue(folder, at: start + .seconds(60 + 120)))
    }

    @Test("Reset forgets every folder")
    func reset() {
        var pacer = DeepRefreshPacer(baseInterval: .seconds(10))
        pacer.recordWalk(of: folder, started: start, ended: start)
        pacer.reset()
        #expect(pacer.isDue(folder, at: start))
    }
}
