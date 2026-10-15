import XCTest
@testable import NotchCore

final class SkinTests: XCTestCase {
    func testThemePreferenceMigrationAndSafeDefault() {
        XCTAssertEqual(MeterTheme.restored(nil), .standard)
        for invalid in ["", "unknown", "RAINBOW", " rainbow "] {
            XCTAssertEqual(MeterTheme.restored(invalid), .standard)
        }
        XCTAssertEqual(MeterTheme.restored("standard"), .standard)
        XCTAssertEqual(MeterTheme.restored("rainbow"), .rainbow)
        XCTAssertEqual(MeterTheme.allCases.map(\.rawValue), ["standard", "rainbow", "aurora", "sunset", "ice"])
        for theme in MeterTheme.allCases {
            XCTAssertEqual(MeterTheme.restored(theme.rawValue), theme)
            XCTAssertEqual(theme.id, theme.rawValue)
            XCTAssertFalse(theme.title.isEmpty)
            XCTAssertEqual(theme.supportsMotion, theme == .rainbow)
        }
        XCTAssertEqual(Set(MeterTheme.allCases.map(\.title)).count, 5)
    }

    func testSpeedRestorationAndFrameBudget() {
        XCTAssertEqual(SkinMotionSpeed.restored(nil), .normal)
        XCTAssertEqual(SkinMotionSpeed.restored("invalid"), .normal)
        for speed in SkinMotionSpeed.allCases {
            XCTAssertEqual(SkinMotionSpeed.restored(speed.rawValue), speed)
            XCTAssertEqual(speed.id, speed.rawValue)
            XCTAssertFalse(speed.title.isEmpty)
        }
        XCTAssertEqual(SkinMotionSpeed.normal.cycleDuration, 8)
        XCTAssertEqual(SkinMotionSpeed.slow.cycleDuration, 12)
        XCTAssertEqual(SkinMotionPolicy.maximumFramesPerSecond, 15)
        XCTAssertEqual(SkinMotionPolicy.frameInterval, 1.0 / 15, accuracy: 1e-12)
    }

    func testStandardDefaultIsStaticAndRainbowSelectionOptsIntoMotion() {
        var policy = SkinMotionPolicy()
        XCTAssertEqual(policy.theme, .standard)
        XCTAssertFalse(policy.isRunning)
        policy.hasVisibleOwnedSurface = true
        XCTAssertFalse(policy.isRunning)
        for theme in MeterTheme.allCases {
            policy.theme = theme
            XCTAssertEqual(policy.isRunning, theme == .rainbow)
        }
        policy.theme = .rainbow
        policy.motionEnabled = false
        XCTAssertFalse(policy.isRunning)
    }

    func testEveryPauseReasonIndependentlyStopsMotion() {
        let active = SkinMotionPolicy(theme: .rainbow, hasVisibleOwnedSurface: true)
        XCTAssertTrue(active.isRunning)
        let blockers: [(WritableKeyPath<SkinMotionPolicy, Bool>, Bool)] = [
            (\.motionEnabled, false), (\.reduceMotion, true), (\.lowPowerMode, true),
            (\.asleep, true), (\.overlayEnabled, false),
            (\.hasVisibleOwnedSurface, false), (\.sessionActive, false)
        ]
        for (key, value) in blockers {
            var policy = active
            policy[keyPath: key] = value
            XCTAssertFalse(policy.isRunning, "Pause flag \(key) was ignored")
            policy[keyPath: key] = active[keyPath: key]
            XCTAssertTrue(policy.isRunning)
        }
    }

    func testVisibleMenuBarOverlayNeedsNoApplicationActivation() {
        // No NSApp.isActive input exists. A visible overlay may animate with another
        // app frontmost; only user-session inactivity prevents it.
        var policy = SkinMotionPolicy(theme: .rainbow, hasVisibleOwnedSurface: true)
        XCTAssertTrue(policy.isRunning)
        policy.sessionActive = false
        XCTAssertFalse(policy.isRunning)
        policy.sessionActive = true
        XCTAssertTrue(policy.isRunning)
    }

    func testInitialSampleAnchorsWithoutCountingPriorUptime() {
        var clock = SkinPhaseClock()
        XCTAssertEqual(clock.phase, 0)
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(clock.update(now: 50_000, running: true), 0)
        XCTAssertTrue(clock.isRunning)
        XCTAssertEqual(clock.update(now: 50_002, running: true), 0.25, accuracy: 1e-12)
    }

    func testNormalAndSlowCyclesWrapAtTheirDurations() {
        for speed in SkinMotionSpeed.allCases {
            var clock = SkinPhaseClock(speed: speed)
            clock.update(now: 0, running: true)
            clock.update(now: speed.cycleDuration / 4, running: true)
            XCTAssertEqual(clock.phase, 0.25, accuracy: 1e-12)
            clock.update(now: speed.cycleDuration, running: true)
            XCTAssertEqual(clock.phase, 0, accuracy: 1e-12)
            clock.update(now: speed.cycleDuration * 3.5, running: true)
            XCTAssertEqual(clock.phase, 0.5, accuracy: 1e-12)
        }
    }

    func testPauseCreditsLastActiveIntervalAndResumeExcludesPausedGap() {
        var clock = SkinPhaseClock()
        clock.update(now: 10, running: true)
        clock.update(now: 12, running: false)
        XCTAssertEqual(clock.phase, 0.25, accuracy: 1e-12)
        XCTAssertFalse(clock.isRunning)
        clock.update(now: 1_000, running: false)
        clock.update(now: 10_000, running: true)
        XCTAssertEqual(clock.phase, 0.25, accuracy: 1e-12)
        clock.update(now: 10_002, running: true)
        XCTAssertEqual(clock.phase, 0.5, accuracy: 1e-12)
        clock.update(now: 10_002, running: false)
        clock.update(now: 10_002, running: true)
        XCTAssertEqual(clock.phase, 0.5, accuracy: 1e-12)
    }

    func testPolicyTransitionsPreservePhaseForEveryPauseReason() {
        let blockers: [(WritableKeyPath<SkinMotionPolicy, Bool>, Bool)] = [
            (\.motionEnabled, false), (\.reduceMotion, true), (\.lowPowerMode, true),
            (\.asleep, true), (\.overlayEnabled, false),
            (\.hasVisibleOwnedSurface, false), (\.sessionActive, false)
        ]
        for (key, value) in blockers {
            var policy = SkinMotionPolicy(theme: .rainbow, hasVisibleOwnedSurface: true)
            let original = policy[keyPath: key]
            var clock = SkinPhaseClock()
            clock.update(now: 0, running: policy.isRunning)
            policy[keyPath: key] = value
            clock.update(now: 2, running: policy.isRunning)
            XCTAssertEqual(clock.phase, 0.25, accuracy: 1e-12)
            clock.update(now: 1_002, running: policy.isRunning)
            policy[keyPath: key] = original
            clock.update(now: 2_002, running: policy.isRunning)
            XCTAssertEqual(clock.phase, 0.25, accuracy: 1e-12)
            clock.update(now: 2_004, running: policy.isRunning)
            XCTAssertEqual(clock.phase, 0.5, accuracy: 1e-12)
        }
    }

    func testBackwardsAndDuplicateClockSamplesCannotReverseOrPoisonPhase() {
        var clock = SkinPhaseClock()
        clock.update(now: 100, running: true)
        clock.update(now: 102, running: true)
        clock.update(now: 102, running: true)
        XCTAssertEqual(clock.phase, 0.25, accuracy: 1e-12)
        clock.update(now: 50, running: true)
        XCTAssertEqual(clock.phase, 0.25, accuracy: 1e-12)
        clock.update(now: 52, running: true)
        XCTAssertEqual(clock.phase, 0.5, accuracy: 1e-12)
    }

    func testNonfiniteAndNegativeSamplesPreservePhaseAndReanchor() {
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            for running in [false, true] {
                var clock = SkinPhaseClock()
                clock.update(now: 0, running: true)
                clock.update(now: 2, running: true)
                clock.update(now: invalid, running: running)
                XCTAssertEqual(clock.phase, 0.25, accuracy: 1e-12)
                XCTAssertEqual(clock.isRunning, running)
                clock.update(now: 100, running: true)
                XCTAssertEqual(clock.phase, 0.25, accuracy: 1e-12)
                clock.update(now: 102, running: true)
                XCTAssertEqual(clock.phase, 0.5, accuracy: 1e-12)
            }
        }
    }

    func testPhaseDependsOnElapsedTimeRatherThanFrameCount() {
        for speed in SkinMotionSpeed.allCases {
            let end = 101.75
            var reference = SkinPhaseClock(speed: speed)
            reference.update(now: 0, running: true)
            reference.update(now: end, running: true)
            for fps in [1, 7, 15, 24, 60, 144] {
                var sampled = SkinPhaseClock(speed: speed)
                sampled.update(now: 0, running: true)
                for frame in 1...Int(end * Double(fps)) {
                    sampled.update(now: Double(frame) / Double(fps), running: true)
                }
                sampled.update(now: end, running: true)
                XCTAssertEqual(sampled.phase, reference.phase, accuracy: 1e-10)
            }
            var irregular = SkinPhaseClock(speed: speed)
            for now in [0.0, 0.017, 0.5, 1.6, 1.61, 8.999, 40.0, 89.2, end] {
                irregular.update(now: now, running: true)
            }
            XCTAssertEqual(irregular.phase, reference.phase, accuracy: 1e-10)
        }
    }

    func testSpeedChangePreservesCurrentPhase() {
        var clock = SkinPhaseClock()
        clock.update(now: 0, running: true)
        clock.update(now: 2, running: true)
        clock.speed = .slow
        XCTAssertEqual(clock.phase, 0.25, accuracy: 1e-12)
        clock.update(now: 5, running: true)
        XCTAssertEqual(clock.phase, 0.5, accuracy: 1e-12)
    }

    func testPhaseRemainsFiniteAndBoundedThroughLargeJumps() {
        for speed in SkinMotionSpeed.allCases {
            var clock = SkinPhaseClock(speed: speed)
            for now in [0.0, 2.5, 1e6, 1e12, Double.greatestFiniteMagnitude, 0, 1] {
                clock.update(now: now, running: true)
                XCTAssertTrue(clock.phase.isFinite)
                XCTAssertGreaterThanOrEqual(clock.phase, 0)
                XCTAssertLessThan(clock.phase, 1)
            }
        }
    }

    func testColorPhaseIsIndependentOfQuotaAndIslandProgress() {
        var reference = SkinPhaseClock()
        reference.update(now: 0, running: true)
        reference.update(now: 2, running: true)
        let usages: [Double?] = [nil, 0, 25, 83, 100]
        for used in usages {
            let quota = QuotaWindow(id: "synthetic", usedPercent: used, durationMinutes: 300, resetsAt: nil)
            let before = quota.remainingPercent
            var island = IslandMotion()
            var clock = SkinPhaseClock()
            clock.update(now: 0, running: true)
            island.advance(expanded: true, elapsed: 0.5, reduceMotion: false)
            clock.update(now: 2, running: true)
            let progress = island.progress
            XCTAssertEqual(clock.phase, reference.phase, accuracy: 1e-12)
            clock.update(now: 4, running: true)
            XCTAssertEqual(quota.remainingPercent, before)
            XCTAssertEqual(island.progress, progress)
        }
    }

    private func window(_ id: String, minutes: Int?) -> QuotaWindow {
        QuotaWindow(id: id, usedPercent: 17, durationMinutes: minutes, resetsAt: nil)
    }

    func testPrimaryWindowChoosesShortestDurationRegardlessOfInputOrder() {
        let short = window("short", minutes: 300), long = window("long", minutes: 10_080)
        for windows in [[long, short], [short, long]] {
            let bucket = QuotaBucket(id: "synthetic", name: "Synthetic", windows: windows)
            XCTAssertEqual(bucket.primaryWindow()?.id, "short")
            XCTAssertEqual(bucket.primaryWindow(preferredID: "missing")?.id, "short")
            XCTAssertEqual(bucket.windows, windows)
        }
    }

    func testPrimaryWindowHonorsExactSelectionIncludingUnknownDuration() {
        let windows = [window("short", minutes: 300), window("long", minutes: 10_080), window("unknown", minutes: nil)]
        let bucket = QuotaBucket(id: "synthetic", name: "Synthetic", windows: windows)
        for selected in windows {
            XCTAssertEqual(bucket.primaryWindow(preferredID: selected.id), selected)
        }
        XCTAssertEqual(bucket.primaryWindow(preferredID: "LONG")?.id, "short")
        XCTAssertEqual(bucket.windows, windows)
    }

    func testPrimaryWindowRanksUnknownLastAndKeepsStableTies() {
        let unknown = window("unknown", minutes: nil), invalid = window("invalid", minutes: 0)
        let first = window("first", minutes: 300), tied = window("tied", minutes: 300)
        let largest = window("largest-valid", minutes: Int.max)
        func primary(_ windows: [QuotaWindow]) -> String? {
            QuotaBucket(id: "synthetic", name: "Synthetic", windows: windows).primaryWindow()?.id
        }
        XCTAssertEqual(primary([unknown, invalid, first, tied]), "first")
        XCTAssertEqual(primary([unknown, tied, first, invalid]), "tied")
        XCTAssertEqual(primary([unknown, largest]), "largest-valid")
        XCTAssertEqual(primary([unknown, invalid]), "unknown")
        XCTAssertEqual(primary([invalid, unknown]), "invalid")
        XCTAssertNil(primary([]))
    }
}
