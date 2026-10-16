import Foundation
import XCTest
@testable import NotchCore

final class NoticeDurationTests: XCTestCase {
    func testEveryChoiceHasStableStorageLabelAndFullyExpandedDwell() {
        XCTAssertEqual(NoticeDuration.allCases, [.short, .standard, .long])
        XCTAssertEqual(NoticeDuration.allCases.map(\.rawValue), ["short", "standard", "long"])
        XCTAssertEqual(NoticeDuration.allCases.map(\.title), ["短", "标准", "长"])
        XCTAssertEqual(NoticeDuration.allCases.map(\.seconds), [2, 4, 6])
        for duration in NoticeDuration.allCases {
            XCTAssertEqual(duration.id, duration.rawValue)
            XCTAssertEqual(NoticeDuration.restored(duration.rawValue), duration)
        }
    }

    func testMissingAndInvalidStoredValuesUseStandardFourSecondDwell() {
        XCTAssertEqual(NoticeDuration.restored(nil), .standard)
        XCTAssertEqual(NoticeDuration.restored(nil).seconds, 4)
        for invalid in ["", "unknown", "SHORT", " standard ", "2", "4", "6"] {
            XCTAssertEqual(NoticeDuration.restored(invalid), .standard)
            XCTAssertEqual(NoticeDuration.restored(invalid).seconds, 4)
        }
    }

    func testPreferencesRoundTripInAnIsolatedTemporarySuite() throws {
        let suiteName = "NotchCoreTests.NoticeDuration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "noticeDuration"

        XCTAssertNil(defaults.string(forKey: key))
        XCTAssertEqual(NoticeDuration.restored(defaults.string(forKey: key)), .standard)
        for duration in NoticeDuration.allCases {
            defaults.set(duration.rawValue, forKey: key)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            XCTAssertEqual(reopened.string(forKey: key), duration.rawValue)
            XCTAssertEqual(NoticeDuration.restored(reopened.string(forKey: key)), duration)
        }

        defaults.set("invalid", forKey: key)
        XCTAssertEqual(NoticeDuration.restored(defaults.string(forKey: key)), .standard)
        defaults.removeObject(forKey: key)
        XCTAssertEqual(NoticeDuration.restored(defaults.string(forKey: key)), .standard)
    }
}
