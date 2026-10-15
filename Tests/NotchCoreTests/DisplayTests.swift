import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchCore

final class DisplayTests: XCTestCase {
    private func fixture(id: UInt32 = 1, key: String? = "synthetic-a", frame: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982),
                         scale: Double = 2, width: Double = 220.25, inset: Double = 32, offset: Double = 0.125) -> DisplaySnapshot {
        let left = frame.midX - width / 2 + offset, right = left + width
        return DisplaySnapshot(id: id, calibrationID: key, name: "Same display name", frame: frame, scale: scale, topInset: inset,
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - inset, width: left - frame.minX, height: inset),
            auxiliaryRight: CGRect(x: right, y: frame.maxY - inset, width: frame.maxX - right, height: inset))
    }
    private func plan(_ displays: [DisplaySnapshot], _ activity: DisplayActivity = DisplayActivity(), _ calibration: [String: Double] = [:]) -> DisplayPlan {
        DisplayPlan.make(snapshots: displays, activity: activity, calibrations: calibration)
    }
    func testCapabilityMatrixKeepsRawEdgesAcrossFamiliesModesOriginsAndScales() throws {
        // Official native resolutions inform screen aspect/size only. Insets and cutout widths
        // below are arbitrary synthetic inputs, NOT measured model-specific hardware values.
        let resolutions = [CGSize(width: 2560, height: 1664), CGSize(width: 2880, height: 1864),
            CGSize(width: 3024, height: 1964), CGSize(width: 3456, height: 2234)]
        var checked = 0
        for pixels in resolutions {
            for pointsPerPixel in [0.5, 0.625, 0.75] {
                for origin in [CGPoint.zero, CGPoint(x: -2100.25, y: 180.5), CGPoint(x: 500.5, y: -1400.25)] {
                    for scale in [1.0, 2.0] {
                        for offset in [-37.125, 0, 61.25] {
                            let frame = CGRect(origin: origin, size: CGSize(width: pixels.width * pointsPerPixel, height: pixels.height * pointsPerPixel))
                            let snapshot = fixture(frame: frame, scale: scale, offset: offset)
                            let result = try XCTUnwrap(plan([snapshot]).targets.first)
                            XCTAssertEqual(result.geometry.notch.minX, snapshot.auxiliaryLeft!.maxX)
                            XCTAssertEqual(result.geometry.notch.maxX, snapshot.auxiliaryRight!.minX)
                            for progress in [0.0, 0.25, 0.5, 0.75, 1] {
                                XCTAssertEqual(result.geometry.frame(progress: progress).maxY, frame.maxY, accuracy: 0.000001)
                                XCTAssertTrue(frame.insetBy(dx: -0.001, dy: -0.001).contains(result.geometry.frame(progress: progress)))
                            }
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 216)
    }
    func testNoNotchFamiliesAndExternalAlwaysUseMenuFallback() {
        for size in [CGSize(width: 2304, height: 1440), CGSize(width: 2560, height: 1600), CGSize(width: 2880, height: 1800), CGSize(width: 3072, height: 1920), CGSize(width: 2408, height: 1506)] {
            let plain = DisplaySnapshot(id: 1, frame: CGRect(origin: .zero, size: size))
            XCTAssertEqual(plan([plain]).decisions.first?.fallback, .noCutout)
            XCTAssertTrue(plan([plain]).targets.isEmpty)
        }
        var external = fixture(); external.builtIn = false
        XCTAssertEqual(plan([external]).decisions.first?.fallback, .external)
    }
    func testInactiveOfflineSleepingAndBothMirrorRolesFailClosed() {
        var value = fixture(); value.online = false
        XCTAssertEqual(plan([value]).decisions.first?.fallback, .offline)
        value = fixture(); value.active = false
        XCTAssertEqual(plan([value]).decisions.first?.fallback, .inactive)
        value = fixture(); value.asleep = true
        XCTAssertEqual(plan([value]).decisions.first?.fallback, .asleep)
        for active in [true, false] {
            value = fixture(); value.mirrored = true; value.active = active
            XCTAssertTrue(plan([value]).targets.isEmpty)
        }
    }
    func testAllSuspensionReasonsRemoveTargetsButRetainEligibleCalibration() {
        var states: [DisplayActivity] = []
        var state = DisplayActivity(); state.overlayEnabled = false; states.append(state)
        state = DisplayActivity(); state.systemSleeping = true; states.append(state)
        state = DisplayActivity(); state.displaysSleeping = true; states.append(state)
        state = DisplayActivity(); state.sessionActive = false; states.append(state)
        state = DisplayActivity(); state.applicationHidden = true; states.append(state)
        state = DisplayActivity(); state.terminating = true; states.append(state)
        for state in states {
            let result = plan([fixture()], state)
            XCTAssertTrue(result.targets.isEmpty); XCTAssertEqual(result.eligible.count, 1); XCTAssertFalse(result.shouldRecheck)
        }
    }
    func testMenuAutohideAndFullscreenVisibleFrameNeverRelocateCutout() throws {
        let baseline = try XCTUnwrap(plan([fixture()]).targets.first)
        for visible in [CGRect.zero, CGRect(x: 0, y: 20, width: 1512, height: 900), CGRect(x: 0, y: 0, width: 1512, height: 982)] {
            var value = fixture(); value.visibleFrame = visible
            XCTAssertEqual(try XCTUnwrap(plan([value]).targets.first).geometry, baseline.geometry)
        }
    }
    func testDuplicateOrMissingRuntimeIDsDoNotCreateTargets() {
        XCTAssertTrue(plan([fixture(), fixture()]).targets.isEmpty)
        XCTAssertEqual(plan([fixture(id: 0)]).decisions.first?.fallback, .duplicateID)
    }
    func testMissingOrAmbiguousUUIDCannotBorrowCalibration() {
        let missing = plan([fixture(key: nil)], DisplayActivity(), ["synthetic-a": -8])
        XCTAssertEqual(missing.targets.first?.geometry.horizontalAdjustment, 0)
        let duplicate = plan([fixture(), fixture(id: 2)], DisplayActivity(), ["synthetic-a": 8])
        XCTAssertEqual(duplicate.targets.count, 2)
        XCTAssertTrue(duplicate.targets.allSatisfy { $0.calibrationID == nil && $0.geometry.horizontalAdjustment == 0 })
        XCTAssertNil(plan([fixture(key: "")]).targets.first?.calibrationID)
    }
    func testReorderPrimaryChangeAndEqualNamesPreserveDisplayCalibration() throws {
        let a = fixture(), b = fixture(id: 2, key: "synthetic-b", offset: -37)
        let calibration = ["synthetic-a": -0.5, "synthetic-b": 4.0]
        let first = plan([a, b], DisplayActivity(), calibration)
        XCTAssertEqual(first, plan([b, a], DisplayActivity(), calibration))
        XCTAssertEqual(first.targets.map(\.geometry.horizontalAdjustment), [-0.5, 4])
        XCTAssertEqual(plan([b], DisplayActivity(), calibration).targets.first?.geometry.horizontalAdjustment, 4)
        XCTAssertEqual(plan([a, b], DisplayActivity(), calibration), first)
    }
    func testScaleOnlyChangeProducesNewPlacementButSameRawBounds() throws {
        let first = try XCTUnwrap(plan([fixture(scale: 1)]).targets.first)
        let second = try XCTUnwrap(plan([fixture(scale: 2)]).targets.first)
        XCTAssertNotEqual(first.geometry, second.geometry)
        XCTAssertEqual(first.geometry.notch, second.geometry.notch)
    }
    func testInvalidScaleAndNonfiniteScreenGeometryFailClosed() {
        for scale in [0.0, -1, .infinity, .nan] {
            XCTAssertEqual(plan([fixture(scale: scale)]).decisions.first?.fallback, .invalidGeometry)
        }
        for frame in [CGRect(x: .nan, y: 0, width: 1512, height: 982), CGRect(x: 0, y: 0, width: .infinity, height: 982), CGRect(x: 0, y: 0, width: -1, height: 982), CGRect.zero] {
            var value = fixture(); value.frame = frame
            XCTAssertEqual(plan([value]).decisions.first?.fallback, .invalidGeometry)
        }
    }
    func testInvalidAuxiliaryRectanglesAndMissingHalfFailClosed() {
        let bad = [CGRect.zero, CGRect(x: 0, y: 950, width: 600, height: -32),
            CGRect(x: 600, y: 982, width: -600, height: -32),
            CGRect(x: 0, y: .nan, width: 600, height: 32), CGRect(x: -1, y: 950, width: 600, height: 32),
            CGRect(x: 0, y: 900, width: 600, height: 82), CGRect(x: 0, y: 949, width: 600, height: 32)]
        for rect in bad {
            var value = fixture(); value.auxiliaryLeft = rect
            XCTAssertEqual(plan([value]).decisions.first?.fallback, .invalidGeometry)
        }
        var missing = fixture(); missing.auxiliaryRight = nil
        XCTAssertEqual(plan([missing]).decisions.first?.fallback, .invalidGeometry)
        for inset in [Double.nan, .infinity, -1, 0, 982] {
            var value = fixture(); value.topInset = inset
            XCTAssertEqual(plan([value]).decisions.first?.fallback, .invalidGeometry)
        }
    }
    func testSmallSafeRegionsNeedNotHaveUndocumentedExactHeight() throws {
        var value = fixture()
        value.auxiliaryLeft = CGRect(x: 0, y: 966, width: value.auxiliaryLeft!.width, height: 16)
        XCTAssertEqual(try XCTUnwrap(plan([value]).targets.first).geometry.notch.height, 32)
    }
    func testInsufficientViewportDoesNotCreateClippedDetails() {
        let small = fixture(frame: CGRect(x: 0, y: 0, width: 360, height: 300), width: 100)
        XCTAssertEqual(plan([small]).decisions.first?.fallback, .insufficientRoom)
    }
    func testTinyCutoutWidthFallsBackBeforeFixedTurnsReverse() {
        XCTAssertEqual(plan([fixture(width: 17.5, inset: 32)]).decisions.first?.fallback, .insufficientRoom)
    }
    func testTinyCutoutDepthFallsBackBeforeFixedTurnsReverse() {
        XCTAssertEqual(plan([fixture(width: 220, inset: 8.5)]).decisions.first?.fallback, .insufficientRoom)
    }
    func testRendererMinimumEnvelopeIsAcceptedExactly() throws {
        let result = try XCTUnwrap(plan([fixture(width: 18, inset: 9)]).targets.first)
        XCTAssertEqual(result.geometry.contourFrame.width, 24)
        XCTAssertEqual(result.geometry.contourFrame.height, 12)
    }
    func testInvalidTransientSnapshotCannotKeepOldPlanOrInventCutout() {
        let first = plan([fixture()]); XCTAssertEqual(first.targets.count, 1)
        var incomplete = fixture(); incomplete.auxiliaryLeft = nil
        XCTAssertTrue(plan([incomplete]).targets.isEmpty)
        XCTAssertTrue(plan([]).targets.isEmpty)
        XCTAssertEqual(plan([fixture()]), first)
    }
}
