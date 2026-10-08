import XCTest
@testable import Featureflip

/// Manual benchmark for the read hot path (#3545). Skipped unless FEATUREFLIP_BENCH=1,
/// because timing assertions flake on shared runners. Run it in a release build and put
/// the printed numbers in the PR description. Budget: at most 100 ns added per repeat read.
final class ReadReportingBenchmarkTests: XCTestCase {

    private let iterations = 1_000_000

    private func makeCore(reporting: Bool) -> SharedFeatureflipCore {
        let core = SharedFeatureflipCore(
            config: FeatureflipConfig(
                clientKey: "bench-\(reporting)",
                baseUrl: "https://localhost",
                context: ["user_id": "u-1"],
                streaming: false,
                sendEvaluationEvents: reporting
            ),
            loader: MockHTTPLoader(),
            readSink: { _ in }
        )
        core.updateSnapshot(["bench-flag": FlagValue(value: .bool(true), variation: "on", reason: "fallthrough")])
        return core
    }

    /// Nanoseconds per `boolVariation`, after a warm-up that also makes the reads repeats.
    private func nsPerRead(_ core: SharedFeatureflipCore) -> Double {
        var trueCount = 0
        for _ in 0..<100_000 where core.boolVariation("bench-flag", default: false) {
            trueCount += 1
        }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations where core.boolVariation("bench-flag", default: false) {
            trueCount += 1
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        // Uses the result so the optimizer cannot drop the loop.
        XCTAssertEqual(trueCount, 100_000 + iterations)
        return Double(elapsed) / Double(iterations)
    }

    func testRepeatReadCostWithReportingOnVersusOff() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FEATUREFLIP_BENCH"] == "1",
            "manual benchmark: run with FEATUREFLIP_BENCH=1 in a release build"
        )
        let off = makeCore(reporting: false)
        let on = makeCore(reporting: true)

        // Best of five interleaved rounds, so one noisy round cannot decide the result.
        var bestOff = Double.infinity
        var bestOn = Double.infinity
        for _ in 0..<5 {
            bestOff = min(bestOff, nsPerRead(off))
            bestOn = min(bestOn, nsPerRead(on))
        }

        print(String(
            format: "[read-reporting bench] repeat boolVariation x%d: off %.1f ns/op, on %.1f ns/op, added %.1f ns/op (budget 100)",
            iterations, bestOff, bestOn, bestOn - bestOff
        ))
        off.release()
        on.release()
    }
}
