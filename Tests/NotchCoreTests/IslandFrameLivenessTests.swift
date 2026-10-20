import XCTest
@testable import NotchCore

final class IslandFrameLivenessTests: XCTestCase {
    func testSilentSourceRecoversOnceAfterBoundedDeliveryGap() {
        var value = IslandFrameLiveness(now: 10)
        XCTAssertEqual(value.probe(at: 10.299, presentationAllowed: true), .wait)
        XCTAssertEqual(value.probe(at: 10.301, presentationAllowed: true), .recover)
        XCTAssertEqual(value.probe(at: 20, presentationAllowed: true), .suspend)
    }
    func testHealthyDeliveryAndSuspensionCannotManufactureRecovery() {
        var value = IslandFrameLiveness(now: 10)
        for step in 1...100 {
            let time = 10 + Double(step) / 60
            value.delivered(at: time)
            XCTAssertEqual(value.probe(at: time, presentationAllowed: true), .wait)
        }
        XCTAssertEqual(value.probe(at: 20, presentationAllowed: false), .suspend)
        XCTAssertFalse(value.recovered)
        value.delivered(at: 21)
        XCTAssertEqual(value.probe(at: 21.1, presentationAllowed: true), .wait)
    }
    func testStoppedOrInvalidClockCannotRestart() {
        var value = IslandFrameLiveness(now: 10)
        for time in [Double.nan, .infinity, 9] {
            value.delivered(at: time)
            XCTAssertEqual(value.probe(at: time, presentationAllowed: true), .wait)
        }
        value.stop(); value.delivered(at: 50)
        XCTAssertEqual(value.probe(at: 100, presentationAllowed: true), .stopped)
        XCTAssertFalse(value.recovered)
    }
}
