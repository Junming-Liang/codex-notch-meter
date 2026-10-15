#if os(macOS)
import AppKit
import NotchCore

/// Synthetic capability/lifecycle injection through the production planner and reconciler.
/// Native windows are mapped to the real hosted screen; no physical model/lid/Spaces claim.
@MainActor
final class DisplayCompatibilityHarness: NSObject {
    private let model: MeterModel
    private let screen: NSScreen
    private let menuAvailable: () -> Bool
    private let completion: (Bool) -> Void
    private var snapshots: [DisplaySnapshot] = []
    private var activity = DisplayActivity()
    private var reduced = true
    private var timer: Timer?
    private var index = 0
    private var stage = 0
    private var passed = true
    private var orientations: [Int: Bool] = [:]
    private var matrixCaptures = 0
    private var expandedChecks = 0
    private var prior: IslandPanelController?
    private var retained: IslandPanelController?
    private var savedPreferences: [String: Any] = [:]
    private var reads = 0
    private var retryBegan: TimeInterval = 0
    private var retryReadCount = 0
    private let profiles: [(String, CGFloat, CGFloat, CGFloat)] = [
        ("small-cutout-synthetic", 180, 24, -20.125),
        ("fractional-cutout-synthetic", 220.5, 32, 20.125),
        ("wide-cutout-synthetic", 260, 35, -0.25),
        ("deep-cutout-synthetic", 300, 40, 0.25)
    ]
    private lazy var coordinator = DisplayCoordinator(model: model, snapshots: { [weak self] in
        guard let self else { return [] }; self.reads += 1; return self.snapshots
    }, activity: { [weak self] in self?.activity ?? DisplayActivity() }, makeIsland: { [unowned self] geometry in
        IslandPanelController(model: self.model, geometry: geometry, startPolling: false,
            reducedMotionOverride: self.reduced, hovered: {}, refresh: {}, settings: {}, quit: {})
    })

    init(model: MeterModel, screen: NSScreen, menuAvailable: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        self.model = model; self.screen = screen; self.menuAvailable = menuAvailable; self.completion = completion
    }
    private func fixture(id: UInt32 = 1, key: String? = "synthetic-a", width: CGFloat = 220, inset: CGFloat = 32,
                         offset: CGFloat = 0, scale: CGFloat? = nil) -> DisplaySnapshot {
        let frame = screen.frame, left = frame.midX - width / 2 + offset, right = left + width
        return DisplaySnapshot(id: id, calibrationID: key, name: "Synthetic equal name", frame: frame,
            scale: scale ?? screen.backingScaleFactor, topInset: inset,
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - inset, width: left - frame.minX, height: inset),
            auxiliaryRight: CGRect(x: right, y: frame.maxY - inset, width: frame.maxX - right, height: inset))
    }
    private func check(_ value: Bool, _ label: String) {
        passed = value && passed
        SmokeDiagnostics.mark("display \(label) valid=\(value)")
    }
    func start() {
        guard model.demo, CommandLine.arguments.contains("--display-test") else { finish(false); return }
        for key in ["overlayEnabled", "horizontalCalibrations", "theme", "preferredBucket", "executablePath"] {
            if let value = UserDefaults.standard.object(forKey: key) { savedPreferences[key] = value }
        }
        model.overlayEnabled = true; model.theme = .standard; model.setContourFixture(left: 100, right: 38)
        for scale in [1, 2] {
            let view = ScaleCalibrationView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
            guard let image = NativeContourBitmap.capture(view, scale: scale, topRowFirst: true) else { finish(false); return }
            let top = image.pixel(x: scale, y: scale), bottom = image.pixel(x: scale, y: 6 * scale)
            let valid = ((top.r > 0.9 && bottom.b > 0.9) || (top.b > 0.9 && bottom.r > 0.9))
                && view.drawingScale == CGSize(width: CGFloat(scale), height: CGFloat(scale))
                && image.representation.pixelsWide == 8 * scale && image.representation.pixelsHigh == 8 * scale
            orientations[scale] = top.r > 0.9
            check(valid, "capture calibration scale=\(scale) CTM=\(view.drawingScale)")
        }
        setProfile()
        let timer = Timer(timeInterval: 0.2, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func setProfile() {
        let profile = profiles[index]
        prior = coordinator.island(for: 1)
        snapshots = [fixture(width: profile.1, inset: profile.2, offset: profile.3)]
        coordinator.refresh(recheck: false)
        if let prior { check(prior.smokeStopped, "changed geometry retired previous controller") }
    }
    private func axis(_ image: NativeContourBitmap, near expected: CGFloat, inset: CGFloat) -> CGFloat? {
        var sum = 0.0, moment = 0.0
        for y in 0..<image.representation.pixelsHigh {
            let py = (CGFloat(y) + 0.5) / CGFloat(image.scale)
            guard py >= 5 && py <= min(15, inset - 10) else { continue }
            for x in 0..<image.representation.pixelsWide {
                let px = (CGFloat(x) + 0.5) / CGFloat(image.scale)
                guard abs(px - expected) < 3 else { continue }
                let pixel = image.pixel(x: x, y: y), weight = pixel.a * max(0, pixel.g - max(pixel.r, pixel.b))
                sum += weight; moment += Double(px) * weight
            }
        }
        return sum > 0.5 ? CGFloat(moment / sum) : nil
    }
    private func captureProfile() {
        guard let island = coordinator.island(for: 1), let view = island.panel.contentView,
              let raw = snapshots.first, let left = raw.auxiliaryLeft, let right = raw.auxiliaryRight else { check(false, "missing matrix controller"); return }
        let frame = island.panel.frame
        let native = abs(frame.maxY - screen.frame.maxY) < 0.001 && frame == island.geometry.frame(progress: 0)
            && view.bounds.origin == .zero && view.frame.origin == .zero && island.renderedViewport == view.bounds.size
            && !island.panel.canBecomeKey && !island.panel.isKeyWindow && island.panel.ignoresMouseEvents && menuAvailable()
        check(native, "matrix=\(profiles[index].0) rawDepth=\(raw.topInset) rawWidth=\(right.minX-left.maxX) declaredScale=\(raw.scale) actualBacking=\(island.panel.backingScaleFactor) nativeFrame=\(frame)")
        for scale in [1, 2] {
            guard let image = NativeContourBitmap.capture(view, scale: scale, topRowFirst: orientations[scale] ?? true, padToWholePixels: true),
                  let l = axis(image, near: left.maxX - 1 - frame.minX, inset: raw.topInset),
                  let r = axis(image, near: right.minX + 1 - frame.minX, inset: raw.topInset) else {
                check(false, "matrix pixel axes unavailable"); continue
            }
            let center = frame.minX + (l + r) / 2, expected = (left.maxX + right.minX) / 2
            let error = center - expected, tolerance = 0.12 / CGFloat(scale)
            let aligned = abs(l + frame.minX - (left.maxX - 1)) <= tolerance
                && abs(r + frame.minX - (right.minX + 1)) <= tolerance && abs(error) <= tolerance
            let lower = CGFloat(min(8 * raw.topInset / 32 + 3, (raw.topInset + 3) / 2) - 2)
            let bottom = CGFloat(raw.topInset) + 1
            let localLeft = left.maxX - 1 - frame.minX, localRight = right.minX + 1 - frame.minX
            var curved = true
            for t in [0.2, 0.4, 0.6, 0.8] {
                let angle: Double = (180 - 90 * t) * Double.pi / 180
                let cosine: Double = cos(angle), sine: Double = sin(angle)
                let dx = lower + lower * CGFloat(cosine), y = bottom - lower + lower * CGFloat(sine)
                for x in [localLeft + dx, localRight - dx] {
                    curved = image.near(CGPoint(x: x, y: y)).contains(where: { $0.chromatic }) && curved
                }
            }
            check(aligned && curved, "matrix axes=\(profiles[index].0) forcedScale=\(scale) centerErrorPoints=\(error) depthNormalizedCircle=\(curved) expectedStrokeRadius=\(lower)")
            matrixCaptures += 1
        }
    }
    @objc private func tick(_ sender: Timer) {
        guard sender === timer else { return }
        if index < profiles.count {
            switch stage {
            case 0:
                captureProfile(); coordinator.island(for: 1)?.beginSmokeExpansion(); stage = 1
            case 1:
                let island = coordinator.island(for: 1)
                check(island?.verifyExpandedLayout(includePixels: false) == true && island?.verifySmokeClickRouting() == true, "matrix expanded Quit/routing=\(profiles[index].0)")
                expandedChecks += 1; island?.collapse(); stage = 2
            default:
                captureProfile(); index += 1; stage = 0
                if index < profiles.count { setProfile() }
                else { beginLifecycle() }
            }
            return
        }
        advanceLifecycle()
    }
    private func beginLifecycle() {
        reduced = false
        snapshots = [fixture(id: 11, key: "synthetic-a"), fixture(id: 12, key: "synthetic-b", offset: 50)]
        coordinator.refresh(recheck: false)
        retained = coordinator.island(for: 12); prior = coordinator.island(for: 11)
        prior?.beginSmokeExpansion()
        let before = prior?.smokeProgress, velocity = prior?.smokeVelocity
        // Reorder, main-display-like ordering and menu/Dock/fullscreen visible-frame changes
        // are deliberately irrelevant to physical-edge geometry.
        snapshots.reverse(); snapshots[0].visibleFrame = .zero; snapshots[1].visibleFrame = screen.visibleFrame
        for _ in 0..<5 { coordinator.refresh(recheck: false) }
        check(coordinator.island(for: 11) === prior && coordinator.island(for: 12) === retained
            && prior?.smokeMotionRunning == true && prior?.smokeProgress == before && prior?.smokeVelocity == velocity,
            "duplicate/Space/autohide events preserve identity and active motion")
        stage = 10
    }
    private func advanceLifecycle() {
        switch stage {
        case 10:
            check((prior?.smokeProgress ?? 0) > 0 && prior?.smokeTargetExpanded == true, "preserved motion advances after duplicate events")
            snapshots = [fixture(id: 11, key: "synthetic-a", offset: 1), fixture(id: 12, key: "synthetic-b", offset: 50)]
            coordinator.refresh(recheck: false)
            check(prior?.smokeStopped == true && coordinator.island(for: 12) === retained, "geometry replaces only affected display")
            model.selectedCalibrationDisplayID = "synthetic-a"; model.setHorizontalAdjustment(-0.5)
            coordinator.refresh(recheck: false)
            check(coordinator.island(for: 11)?.geometry.horizontalAdjustment == -0.5
                && coordinator.island(for: 12) === retained, "calibration is isolated by UUID, not identical names")
            prior = coordinator.island(for: 11)
            snapshots = [fixture(id: 12, key: "synthetic-b", offset: 50)]
            coordinator.refresh(recheck: false)
            check(prior?.smokeStopped == true && coordinator.island(for: 12) === retained, "disconnect retires only removed display")
            snapshots.append(fixture(id: 21, key: "synthetic-a"))
            coordinator.refresh(recheck: false)
            check(coordinator.island(for: 21)?.geometry.horizontalAdjustment == -0.5, "reconnect new runtime ID retains same UUID correction")
            prior = coordinator.island(for: 21)
            snapshots = [fixture(id: 21, key: nil)]
            coordinator.refresh(recheck: false)
            check(prior?.smokeStopped == true && coordinator.island(for: 21)?.geometry.horizontalAdjustment == 0
                && model.calibrationDisplays.isEmpty, "missing identity uses zero without losing stored calibration")
            snapshots = [fixture(id: 21, key: "synthetic-a"), fixture(id: 22, key: "synthetic-a", offset: 50)]
            coordinator.refresh(recheck: false)
            check(coordinator.islands.count == 2 && coordinator.islands.allSatisfy { $0.geometry.horizontalAdjustment == 0 }
                && model.calibrationDisplays.isEmpty, "ambiguous identity cannot borrow calibration")
            snapshots = [fixture(id: 21, key: "synthetic-a")]
            coordinator.refresh(recheck: false); model.selectedCalibrationDisplayID = "synthetic-a"; model.setHorizontalAdjustment(0)
            coordinator.refresh(recheck: false)
            check(model.horizontalCalibrations["synthetic-a"] == nil && coordinator.island(for: 21)?.geometry.horizontalAdjustment == 0, "reset clears restored correction")
            prior = coordinator.island(for: 21)
            snapshots = [fixture(id: 21, key: "synthetic-new-identity")]
            coordinator.refresh(recheck: false)
            check(prior?.smokeStopped == true && coordinator.island(for: 21) !== prior,
                "reused runtime ID with changed UUID retires old hover state")
            stage = 11
        case 11:
            prior = coordinator.island(for: 21)
            snapshots = [fixture(id: 21, key: "synthetic-new-identity", scale: screen.backingScaleFactor == 1 ? 2 : 1)]
            coordinator.refresh(recheck: false)
            check(prior?.smokeStopped == true && coordinator.island(for: 21) != nil, "scale-only reconfiguration replaces controller")
            prior = coordinator.island(for: 21)
            snapshots[0].auxiliaryRight = nil
            coordinator.refresh()
            check(prior?.smokeStopped == true && coordinator.islands.isEmpty && coordinator.hasPendingRefresh, "transient invalid data removes old hit region immediately")
            // A delayed retry must fetch fresh input, not revive the invalid old plan.
            snapshots = [fixture(id: 21, key: "synthetic-a")]
            retryReadCount = reads; retryBegan = ProcessInfo.processInfo.systemUptime; stage = 12
        case 12:
            let elapsed = ProcessInfo.processInfo.systemUptime - retryBegan
            guard elapsed >= 0.7 && (reads >= retryReadCount + 2 || elapsed >= 2) else { return }
            let completionElapsed = coordinator.lastRefreshAt - retryBegan
            check(coordinator.island(for: 21) != nil && reads == retryReadCount + 2 && !coordinator.hasPendingRefresh
                && completionElapsed >= 0 && completionElapsed <= 2,
                "150/600ms bounded retries read fresh snapshots reads=\(reads-retryReadCount) completedAfter=\(completionElapsed) observedAfter=\(elapsed)")
            exerciseFallbacks()
            stage = 13
        case 13:
            // In-flight topology retry followed by suspension must never recreate a hidden panel.
            snapshots = [fixture(id: 21, key: "synthetic-a")]; activity = DisplayActivity(); coordinator.refresh()
            prior = coordinator.island(for: 21); activity.displaysSleeping = true; coordinator.refresh()
            retryReadCount = reads; retryBegan = ProcessInfo.processInfo.systemUptime; stage = 14
            check(prior?.smokeStopped == true && coordinator.islands.isEmpty && !coordinator.hasPendingRefresh,
                "display sleep cancels retry and all owned panel timers")
        case 14:
            guard ProcessInfo.processInfo.systemUptime - retryBegan >= 0.7 else { return }
            check(reads == retryReadCount && coordinator.islands.isEmpty, "suspended retry cannot resurrect controller")
            activity = DisplayActivity(); coordinator.refresh(recheck: false)
            check(coordinator.islands.count == 1, "display wake rereads and restores eligible overlay")
            var states: [(String, DisplayActivity)] = []
            var value = DisplayActivity(); value.systemSleeping = true; states.append(("system-sleep", value))
            value = DisplayActivity(); value.sessionActive = false; states.append(("session-inactive", value))
            value = DisplayActivity(); value.applicationHidden = true; states.append(("application-hidden", value))
            value = DisplayActivity(); value.overlayEnabled = false; states.append(("overlay-disabled", value))
            for (label, state) in states {
                prior = coordinator.islands.first; activity = state; model.overlayEnabled = state.overlayEnabled
                coordinator.refresh()
                check(prior?.smokeStopped == true && coordinator.islands.isEmpty && !coordinator.hasPendingRefresh && menuAvailable(), "suspend=\(label)")
                activity = DisplayActivity(); model.overlayEnabled = true; coordinator.refresh(recheck: false)
                check(coordinator.islands.count == 1, "resume=\(label)")
            }
            guard let geometry = coordinator.islands.first?.geometry else { finish(false); return }
            let active = IslandPanelController(model: model, geometry: geometry, startPolling: true, reducedMotionOverride: false,
                hovered: {}, refresh: {}, settings: {}, quit: {})
            active.beginSmokeExpansion()
            check(active.verifyDisplayStopIsInert(), "actual pointer/motion sources reject retired callbacks")
            coordinator.refresh()
            check(coordinator.verifyRetiredRefreshIsInert(), "termination rejects retired topology callbacks")
            var after: [String: Any] = [:]
            for key in savedPreferences.keys { if let value = UserDefaults.standard.object(forKey: key) { after[key] = value } }
            let allKeys = ["overlayEnabled", "horizontalCalibrations", "theme", "preferredBucket", "executablePath"]
            let absentUnchanged = allKeys.filter { savedPreferences[$0] == nil }.allSatisfy { UserDefaults.standard.object(forKey: $0) == nil }
            check(NSDictionary(dictionary: savedPreferences).isEqual(to: after) && absentUnchanged, "synthetic preferences never persisted")
            finish(passed && matrixCaptures == profiles.count * 4 && expandedChecks == profiles.count && menuAvailable())
        default: finish(false)
        }
    }
    private func exerciseFallbacks() {
        let base = fixture(id: 21, key: "synthetic-a")
        var cases: [(String, [DisplaySnapshot])] = []
        var value = base; value.topInset = 0; value.auxiliaryLeft = nil; value.auxiliaryRight = nil; cases.append(("nonnotched-or-compatibility-mode", [value]))
        value = base; value.builtIn = false; cases.append(("external-with-notchlike-data", [value]))
        value = base; value.online = false; cases.append(("offline", [value]))
        value = base; value.active = false; cases.append(("inactive", [value]))
        value = base; value.asleep = true; cases.append(("per-display-sleep", [value]))
        value = base; value.mirrored = true; cases.append(("mirror-primary", [value]))
        value.active = false; cases.append(("mirror-secondary", [value]))
        cases.append(("closed-lid-built-in-absent", [])); cases.append(("duplicate-runtime-ID", [base, base]))
        for (label, displays) in cases {
            prior = coordinator.islands.first; snapshots = displays; coordinator.refresh(recheck: false)
            check(prior?.smokeStopped == true && coordinator.islands.isEmpty && menuAvailable() && model.displayNotice != nil, "fallback=\(label)")
            snapshots = [base]; coordinator.refresh(recheck: false)
            check(coordinator.islands.count == 1, "recover=\(label)")
        }
    }
    func stop() { timer?.invalidate(); timer = nil; coordinator.stop() }
    private func finish(_ valid: Bool) {
        stop()
        print(valid ? "DISPLAY_OK: production capability reconciliation, synthetic family pixels and lifecycle checks passed; no physical-model claim" : "DISPLAY_FAILED: capability or lifecycle regression")
        completion(valid)
    }
}
#endif
