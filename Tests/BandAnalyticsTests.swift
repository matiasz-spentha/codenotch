import XCTest
@testable import Codenotch

final class BandAnalyticsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000)
    func forecast(_ values: [Double], resetOffset: Double = 3600, oldCycle: Bool = false) -> BandForecast? {
        let reset = now.addingTimeInterval(resetOffset)
        let samples = values.enumerated().map { index, usage in
            BandSample(key: "codex/primary", time: now.addingTimeInterval(Double(index - values.count + 1) * 3600),
                       reset: reset.addingTimeInterval(oldCycle ? -86400 : 0), usage: usage)
        }
        return BandAnalytics.forecast(samples: samples, key: "codex/primary",
            window: LimitWindow(id: "primary", label: "Session", usedFraction: values.last, resetsAt: reset), now: now)
    }
    func testLinearProjection() { XCTAssertEqual(forecast([0.2, 0.3, 0.4])!.projected, 0.5, accuracy: 0.001) }
    func testNoHistoryNoPrediction() { XCTAssertNil(forecast([0.2])) }
    func testPreviousCycleExcluded() { XCTAssertNil(forecast([0.2, 0.4], oldCycle: true)) }
    func testExpiredResetExcluded() { XCTAssertNil(forecast([0.2, 0.4], resetOffset: -1)) }
    func testFallingUsageSuppressesPrediction() { XCTAssertNil(forecast([0.7, 0.3])) }
    func testExhaustionRisk() { XCTAssertEqual(forecast([0.4, 0.8])?.risk, 2) }
    func testFlatUsagePreservesHeadroom() { XCTAssertEqual(forecast([0.3, 0.3])!.projected, 0.3, accuracy: 0.001) }
}
