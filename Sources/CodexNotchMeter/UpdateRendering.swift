#if os(macOS)
import AppKit
import Combine
import QuartzCore
import NotchCore

/// Demo-only observations of the real panel and normal main-run-loop view updates.
/// Synthetic pointer input is local to this controller; no system events are posted.
/// This is neither a screen capture nor GPU scanout or physical smoothness evidence.
@MainActor
final class UpdateRenderHarness: NSObject {
    private enum Scenario: String, CaseIterable {
        case initial, unchanged, readFailed, shortDwell, standardDwell, longDwell, secondaryChanged
        case identityFreeChange, metadataFreeChange, recoveryDwell
        case movingPromotion, coalescing, armedPromotion, reducedMotion, retiredTimer

        var fixtureIndex: Int {
            switch self {
            case .initial: return 0
            case .unchanged: return 2
            case .readFailed: return 3
            case .secondaryChanged: return 4
            case .identityFreeChange: return 5
            case .metadataFreeChange: return 6
            default: return 1
            }
        }
        var rejectsNotice: Bool { self == .initial || self == .unchanged || self == .readFailed }
        var duration: NoticeDuration {
            switch self {
            case .standardDwell: return .standard
            case .longDwell, .recoveryDwell: return .long
            default: return .short
            }
        }
    }
    private enum Phase: String {
        case idle, rejected, opening, holding, closing, closed
        case expanded, promotedHold, refitOpening, refitExpanded, refitSettled, refitClosing
        case replacementHold, stopped
    }
    private struct Fixture {
        let name: String
        let snapshot: QuotaSnapshot
        let result: QuotaUpdate
    }
    private let model: MeterModel
    private let screen: NSScreen
    private let completion: (Bool) -> Void
    private var controller: IslandPanelController?
    private var geometry: IslandGeometry?
    private var refittedGeometry: IslandGeometry?
    private var fixtures: [Fixture] = []
    private var timer: Timer?
    private var started = false
    private var finished = false
    private var passed = true
    private var scenarioIndex = 0
    private var phase: Phase = .idle
    private var startedAt: TimeInterval = 0
    private var phaseStarted: TimeInterval = 0
    private var scenarioCreatedAt: TimeInterval = 0
    private var shownAt: TimeInterval = 0
    private var targetReachedAt: TimeInterval?
    private var noticePaintReadyAt: TimeInterval?
    private var noticeArmedAt: TimeInterval?
    private var originalNoticeDeadline: TimeInterval?
    private var replacedAt: TimeInterval = 0
    private var closingAt: TimeInterval?
    private var lastSampleCount = 0
    private var totalSamples = 0
    private var nativeProbes = 0
    private var expandedChecks = 0
    private var rejectedChecks = 0
    private var completedDwells: Set<NoticeDuration> = []
    private var secondaryVerified = false
    private var genericVerified: Set<String> = []
    private var deliveryQueue = NoticeDeliveryQueue<RefreshNotice>()
    private var noticeSubscription: AnyCancellable?
    private var settingSubscription: AnyCancellable?
    private var noticePublications = 0
    private var nilPublications = 0
    private var deliveryChecks: Set<String> = []
    private var recoveryReadAt: Date?
    private var recoveryResetAt: Date?
    private var unchangedActiveVerified = false
    private var recoveryPaintVerified = false
    private var longDwellPointerSamples = 0
    private var longDwellSettingChanged = false
    private var longDwellDuplicateChecks = 0
    private var longReadinessDelayVerified = false
    private var longDwellVerified = false
    private var targetVerified = false
    private var oldDeadlineVerified = false
    private var retainsNoticeWhileClosing = false
    private var activeNotice: RefreshNotice?
    private var originalNoticeSetting: Bool?
    private var originalDurationSetting: NoticeDuration?
    private var savedPreferences: [String: Any]?
    private weak var initialKey: NSWindow?
    private var scenario: Scenario { Scenario.allCases[scenarioIndex] }
    private var reduced: Bool { scenario == .reducedMotion }

    init(model: MeterModel, screen: NSScreen, completion: @escaping (Bool) -> Void) {
        self.model = model; self.screen = screen; self.completion = completion
        super.init()
    }

    func start() {
        guard !started, !finished else { return }
        started = true
        guard model.demo, CommandLine.arguments.contains("--update-test") else { finish(false); return }
        startedAt = CACurrentMediaTime(); initialKey = NSApp.keyWindow
        do { fixtures = try makeFixtures() }
        catch { SmokeDiagnostics.mark("update synthetic parser fixture failed"); finish(false); return }
        guard let base = makeGeometry(contentHeight: 180), let fitted = makeGeometry(contentHeight: 300) else {
            SmokeDiagnostics.mark("update synthetic hosted-screen geometry unavailable"); finish(false); return
        }
        geometry = base; refittedGeometry = fitted
        check(base.updateProgress > 0 && base.updateProgress < 1
            && base.frame(progress: base.updateProgress).height < base.frame(progress: 1).height
            && base.hasSameAnchor(as: fitted) && fitted.contentHeight > base.contentHeight,
            "intermediate target and same-anchor content-fit endpoints")
        originalNoticeSetting = model.refreshNoticesEnabled; originalDurationSetting = model.noticeDuration
        savedPreferences = noticePreferences()
        check(model.noticeDuration == .standard && NoticeDuration.standard.seconds == 4
            && NoticeDuration.allCases.map(\.seconds) == [2, 4, 6]
            && NoticeDuration.allCases.allSatisfy { NoticeDuration.restored($0.rawValue) == $0 }
            && NoticeDuration.restored(nil) == .standard && NoticeDuration.restored("invalid") == .standard,
            "duration storage round-trips all choices and defaults safely to four seconds")
        model.refreshNoticesEnabled = false; model.refreshNoticesEnabled = true
        for duration in NoticeDuration.allCases { model.noticeDuration = duration }
        model.noticeDuration = .standard
        check(preferencesUnchanged, "demo notice and duration settings never persist")
        observeNoticePipeline()
        do { try verifyNoticePipeline() }
        catch { check(false, "model delivery fixture failed error=\(error)") }
        guard passed else { finish(false); return }
        startScenario()
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private func makeGeometry(contentHeight: CGFloat) -> IslandGeometry? {
        let frame = screen.frame, width: CGFloat = 220, inset: CGFloat = 32
        let left = frame.midX - width / 2, right = frame.midX + width / 2
        guard let notch = NotchGeometry.calculate(screen: frame, topInset: Double(inset),
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - inset, width: left - frame.minX, height: inset),
            auxiliaryRight: CGRect(x: right, y: frame.maxY - inset, width: frame.maxX - right, height: inset)) else { return nil }
        var geometry = IslandGeometry(notch: notch, screen: frame, backingScale: screen.backingScaleFactor, contentHeight: contentHeight)
        // These fixtures have no music accessories. Match the controller's idle
        // accessory spring so full-geometry equality tests only endpoint changes.
        geometry.musicAccessoryProgress = 0
        return geometry
    }

    private func makeFixtures() throws -> [Fixture] {
        // Relative dates remain fresh throughout this bounded run. Identity is synthetic,
        // stays in the parser/tracker, and is never printed or passed to a presentation.
        let base = Date().addingTimeInterval(-30), reset = base.addingTimeInterval(3600)
        func snapshot(used: Double, secondary: Double = 64, offset: TimeInterval) throws -> QuotaSnapshot {
            let json = "{\"accountId\":\"synthetic-native-update\",\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":\(used),\"windowDurationMins\":300,\"resetsAt\":\(reset.timeIntervalSince1970)},\"secondary\":{\"usedPercent\":\(secondary),\"windowDurationMins\":10080,\"resetsAt\":\(reset.timeIntervalSince1970)}}}"
            return try QuotaParser.parse(Data(json.utf8), fetchedAt: base.addingTimeInterval(offset))
        }
        let initial = try snapshot(used: 40.125, offset: 0)
        let decreased = try snapshot(used: 40.375, offset: 5)
        let unchanged = try snapshot(used: 40.375, offset: 10)
        let secondary = try snapshot(used: 40.375, secondary: 64.25, offset: 15)
        var tracker = QuotaUpdateTracker()
        let first = tracker.record(initial, at: initial.fetchedAt)
        let second = tracker.record(decreased, at: decreased.fetchedAt)
        let third = tracker.record(unchanged, at: unchanged.fetchedAt)
        let fourth = tracker.record(secondary, at: secondary.fetchedAt)
        let failed = tracker.recordFailure(at: base.addingTimeInterval(20))
        var values = [Fixture(name: "initial", snapshot: initial, result: first),
            Fixture(name: "fractional-decrease", snapshot: decreased, result: second),
            Fixture(name: "unchanged", snapshot: unchanged, result: third),
            Fixture(name: "failed-read", snapshot: unchanged, result: failed),
            Fixture(name: "secondary-changed", snapshot: secondary, result: fourth)]
        let firstCandidate = candidate(for: values[0], duration: .standard)
        let unchangedCandidate = candidate(for: values[2], duration: .standard)
        let failedCandidate = candidate(for: values[3], duration: .standard)
        check(makeNotice(for: values[0], duration: .standard) == nil && !firstCandidate.isEligible
            && firstCandidate.change == .updated(reason: .initial) && first.previousFetchedAt == nil,
            "initial read produces no factory notice and no eligible proposal")
        let changed = makeNotice(for: values[1], duration: .standard)
        check(changed?.isEligible == true && changed?.title == "额度已更新"
            && changed?.detail == "本次减少 0.25 个百分点" && changed?.change == .decreased(percentagePoints: 0.25)
            && second.previousFetchedAt == initial.fetchedAt && second.fetchedAt == decreased.fetchedAt,
            "fractional delta is absolute percentage points with comparable interval")
        check(QuotaFormatting.percent(59.875) != QuotaFormatting.percent(59.625)
            && QuotaFormatting.points(0.25) == "0.25" && QuotaFormatting.points(0.001) == "<0.01",
            "fractional endpoints stay distinct and tiny decreases never become zero")
        check(makeNotice(for: values[2], duration: .standard) == nil && !unchangedCandidate.isEligible
            && third.kind == .unchanged && unchangedCandidate.change == .unchanged,
            "unchanged read produces no factory notice and no eligible proposal")
        check(makeNotice(for: values[3], duration: .standard) == nil && !failedCandidate.isEligible
            && failed.kind == .readFailed && failed.fetchedAt == nil && failed.previousFetchedAt == nil
            && failedCandidate.change == nil,
            "failed read produces no factory notice and no comparison claim")
        let secondaryNotice = makeNotice(for: values[4], duration: .short)
        check(secondaryNotice?.isEligible == true && secondaryNotice?.window?.id == "codex:secondary"
            && secondaryNotice?.change == .decreased(percentagePoints: 0.25)
            && fourth.window(bucketID: "codex", windowID: "codex:primary")?.change == .unchanged,
            "unchanged preferred primary selects the actually changed secondary")
        // Actual parser -> tracker -> notice factory path, without optional
        // backend fields. These are synthetic public-schema responses, not users.
        for identityAvailable in [false, true] {
            var genericTracker = QuotaUpdateTracker()
            let identity = identityAvailable ? ",\"accountId\":\"synthetic-native-generic\"" : ""
            let metadata = identityAvailable ? "" : ",\"windowDurationMins\":300,\"resetsAt\":\(reset.timeIntervalSince1970)"
            var changedFixture: Fixture?
            for (index, used) in [20.0, 20.0, 20.125].enumerated() {
                let json = "{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":\(used)\(metadata)}}\(identity)}"
                let current = try QuotaParser.parse(Data(json.utf8), fetchedAt: base.addingTimeInterval(Double(index) * 5))
                let event = genericTracker.record(current, at: current.fetchedAt)
                let fixture = Fixture(name: identityAvailable ? "metadata-free-change" : "identity-free-change", snapshot: current, result: event)
                let notice = makeNotice(for: fixture, duration: .short)
                if index < 2 {
                    check(notice == nil, "optional-field fallback initial/unchanged reads stay silent")
                } else {
                    check(notice?.isEligible == true && notice?.title == "额度已更新"
                        && notice?.detail == "当前剩余额度已更新，未计算消耗差值"
                        && notice?.window?.remainingPercent == 79.875 && event.previousFetchedAt == nil
                        && notice?.change == .updated(reason: identityAvailable ? .dataUnavailable : .identityUnavailable),
                        "optional-field fallback keeps actual current value without invented consumption")
                    changedFixture = fixture
                }
            }
            guard let changedFixture else { throw MeterError.noQuota }
            values.append(changedFixture)
        }
        return values
    }

    private func makeNotice(for fixture: Fixture, duration: NoticeDuration) -> RefreshNotice? {
        let bucket = fixture.snapshot.buckets.first
        return RefreshNotice.make(result: fixture.result, snapshot: fixture.snapshot,
            preferredBucketID: bucket?.id, preferredWindowID: bucket?.windows.first?.id,
            duration: duration, receivedAt: fixture.result.observedAt)
    }

    /// Deliberately bypass the factory only to verify the controller's defensive gate.
    private func candidate(for fixture: Fixture, duration: NoticeDuration) -> RefreshNotice {
        RefreshNotice(id: UUID(), receivedAt: fixture.result.observedAt, result: fixture.result,
            bucketID: fixture.snapshot.buckets.first?.id, window: fixture.snapshot.buckets.first?.windows.first,
            duration: duration)
    }

    /// Subscribe to actual model events, including nil invalidation, and use the
    /// production queue. Only its clock/blocker input is synthetic; no account I/O.
    private func observeNoticePipeline() {
        noticeSubscription = model.$refreshNotice.dropFirst().sink { [weak self] notice in
            guard let self else { return }
            self.noticePublications += 1
            guard let notice else {
                self.nilPublications += 1
                self.deliveryQueue.invalidate()
                self.controller?.dismissRefreshNotice()
                return
            }
            guard notice.isEligible, let fetchedAt = notice.result.fetchedAt else {
                self.check(false, "model published ineligible notice id=\(notice.id) eligible=\(notice.isEligible) fetchedAt=\(String(describing: notice.result.fetchedAt))")
                self.deliveryQueue.invalidate()
                return
            }
            self.deliveryQueue.enqueue(notice, receivedAt: notice.receivedAt,
                fetchedAt: fetchedAt, resetsAt: notice.window?.resetsAt)
        }
        settingSubscription = model.$refreshNoticesEnabled.dropFirst().removeDuplicates().sink { [weak self] enabled in
            guard let self, !enabled else { return }
            self.deliveryQueue.invalidate()
            self.controller?.dismissRefreshNotice()
        }
    }

    private func readNoticeFixture(remaining: Double, at date: Date, reset: Date,
        identity: String = "synthetic-native-delivery") throws {
        let json = "{\"accountId\":\"\(identity)\",\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":\(100 - remaining),\"windowDurationMins\":300,\"resetsAt\":\(reset.timeIntervalSince1970)}}}"
        let snapshot = try QuotaParser.parse(Data(json.utf8), fetchedAt: date)
        model.setNoticeReadFixture(snapshot, at: date)
    }

    private func seedNoticeFixture(at date: Date, reset: Date) throws {
        model.setNoticeFailureFixture(.signedOut, at: date.addingTimeInterval(-1))
        try readNoticeFixture(remaining: 60, at: date, reset: reset)
        check(model.refreshNotice == nil && !deliveryQueue.isPending,
            "model initial fixture stays silent after explicit continuity invalidation publications=\(noticePublications) nilPublications=\(nilPublications)")
    }

    private func verifyNoticePipeline() throws {
        let base = Date().addingTimeInterval(-30), reset = base.addingTimeInterval(3600)
        // The same queue blocker represents hover, an open menu and Settings.
        // Advance the clock eleven seconds, never sleep eleven seconds per case.
        for blocker in ["hover", "menu", "settings"] {
            try seedNoticeFixture(at: base, reset: reset)
            try readNoticeFixture(remaining: 55, at: base.addingTimeInterval(1), reset: reset)
            guard let notice = model.refreshNotice else { check(false, "\(blocker) missing published change"); return }
            let deliveredAt = base.addingTimeInterval(12), before = noticePublications
            let blocked = deliveryQueue.candidate(at: deliveredAt, blocked: true)
            check(blocked == nil && deliveryQueue.isPending,
                "\(blocker) preserves pending event after eleven seconds id=\(notice.id) pending=\(deliveryQueue.isPending)")
            try readNoticeFixture(remaining: 55, at: deliveredAt, reset: reset)
            let deliverable = deliveryQueue.candidate(at: deliveredAt, blocked: false)
            check(noticePublications == before && model.refreshNotice?.id == notice.id && deliverable?.id == notice.id,
                "\(blocker) unchanged read preserves pending event publications=\(noticePublications-before) expectedID=\(notice.id) actualID=\(String(describing: deliverable?.id))")
            deliveryQueue.didDeliver()
            let repeated = deliveryQueue.candidate(at: deliveredAt, blocked: false)
            check(repeated == nil && !deliveryQueue.isPending, "\(blocker) successful delivery consumes queue once")
            deliveryChecks.insert(blocker)
            print("UPDATE_DELIVERY_OK: blocker=\(blocker) blockedSeconds=11 latest=true deliveries=1 unchangedPublications=0")
        }
        try seedNoticeFixture(at: base, reset: reset)
        try readNoticeFixture(remaining: 55, at: base.addingTimeInterval(1), reset: reset)
        let olderID = model.refreshNotice?.id
        try readNoticeFixture(remaining: 50, at: base.addingTimeInterval(2), reset: reset)
        guard let newest = model.refreshNotice, let newestFetchedAt = newest.result.fetchedAt else {
            check(false, "newest replacement missing model event or fetched timestamp"); return
        }
        let newestCandidate = deliveryQueue.candidate(at: base.addingTimeInterval(13), blocked: false)
        check(olderID != newest.id && newestCandidate?.id == newest.id && newestCandidate?.window?.remainingPercent == 50,
            "newest pending numeric event replaces older id old=\(String(describing: olderID)) new=\(newest.id) actual=\(String(describing: newestCandidate?.id))")
        deliveryQueue.didDeliver()
        deliveryQueue.enqueue(newest, receivedAt: newest.receivedAt,
            fetchedAt: newestFetchedAt, resetsAt: newest.window?.resetsAt)
        check(deliveryQueue.candidate(at: base.addingTimeInterval(13), blocked: false) == nil,
            "newest replacement delivers only once even if its publication is replayed")
        deliveryChecks.insert("newest")
        print("UPDATE_REPLACEMENT_OK: newest=true currentRemaining=50 deliveries=1")

        for boundary in ["accountSwitch", "failure", "disabled"] {
            try seedNoticeFixture(at: base, reset: reset)
            try readNoticeFixture(remaining: 55, at: base.addingTimeInterval(1), reset: reset)
            check(deliveryQueue.isPending, "\(boundary) begins with a pending model event")
            let before = nilPublications
            switch boundary {
            case "accountSwitch":
                try readNoticeFixture(remaining: 50, at: base.addingTimeInterval(2), reset: reset,
                    identity: "synthetic-native-other-account")
            case "failure": model.setNoticeFailureFixture(.timedOut, at: base.addingTimeInterval(2))
            default: model.refreshNoticesEnabled = false
            }
            check(!deliveryQueue.isPending && deliveryQueue.candidate(at: base.addingTimeInterval(12), blocked: false) == nil
                && (boundary == "disabled" || (model.refreshNotice == nil && nilPublications > before)),
                "\(boundary) invalidates queued notice pending=\(deliveryQueue.isPending) nilPublications=\(nilPublications-before) modelID=\(String(describing: model.refreshNotice?.id))")
            model.refreshNoticesEnabled = true
            deliveryChecks.insert(boundary)
            print("UPDATE_INVALIDATION_OK: kind=\(boundary) pending=false")
        }

        // Check both timestamps independently and prune invalid entries even when
        // ordinary interaction prevents delivery. Equality at 180 s remains valid.
        let now = base.addingTimeInterval(1000)
        for reason in ["receivedExpired", "fetchedExpired", "resetDue", "receivedFuture", "fetchedFuture"] {
            deliveryQueue = NoticeDeliveryQueue<RefreshNotice>()
            let receivedAt = reason == "receivedExpired" ? now.addingTimeInterval(-180.001)
                : reason == "receivedFuture" ? now.addingTimeInterval(1) : now
            let fetchedAt = reason == "fetchedExpired" ? now.addingTimeInterval(-180.001)
                : reason == "fetchedFuture" ? now.addingTimeInterval(1) : now
            deliveryQueue.enqueue(newest, receivedAt: receivedAt, fetchedAt: fetchedAt,
                resetsAt: reason == "resetDue" ? now : reset)
            check(deliveryQueue.isPending, "\(reason) begins with an actual queued entry")
            let candidate = deliveryQueue.candidate(at: now, blocked: true)
            check(candidate == nil && !deliveryQueue.isPending,
                "queue invalidates \(reason) while blocked receivedAge=\(now.timeIntervalSince(receivedAt)) fetchedAge=\(now.timeIntervalSince(fetchedAt)) resetDue=\(reason == "resetDue") pending=\(deliveryQueue.isPending)")
            deliveryChecks.insert(reason)
            print("UPDATE_QUEUE_GUARD_OK: kind=\(reason) blocked=true pending=false")
        }
        deliveryQueue = NoticeDeliveryQueue<RefreshNotice>()
        deliveryQueue.enqueue(newest, receivedAt: now.addingTimeInterval(-180),
            fetchedAt: now.addingTimeInterval(-180), resetsAt: reset)
        check(deliveryQueue.candidate(at: now, blocked: false)?.id == newest.id,
            "queue retains eligible event at inclusive 180-second boundary")
        deliveryQueue.invalidate()
        check(!deliveryQueue.isPending, "explicit queue invalidation clears inclusive-boundary candidate")
        deliveryChecks.insert("ageBoundary")
        print("UPDATE_QUEUE_BOUNDARY_OK: seconds=180 eligible=true invalidated=true")

        for kind in ["timedOut", "disconnected", "longGap"] {
            try seedNoticeFixture(at: base, reset: reset)
            if kind != "longGap" {
                model.setNoticeFailureFixture(kind == "timedOut" ? .timedOut : .disconnected,
                    at: base.addingTimeInterval(1))
            }
            let readAt = base.addingTimeInterval(kind == "longGap" ? 181 : 2)
            try readNoticeFixture(remaining: 50, at: readAt, reset: reset)
            let notice = model.refreshNotice
            let reason: QuotaUpdateReason = kind == "longGap" ? .stale : .previousReadFailed
            check(notice?.isEligible == true && notice?.change == .updated(reason: reason)
                && notice?.window?.remainingPercent == 50 && notice?.result.previousFetchedAt == nil
                && deliveryQueue.candidate(at: readAt, blocked: false)?.id == notice?.id,
                "\(kind) recovery publishes honest current value eligible=\(notice?.isEligible == true) change=\(String(describing: notice?.change)) current=\(String(describing: notice?.window?.remainingPercent)) previous=\(String(describing: notice?.result.previousFetchedAt))")
            deliveryQueue.didDeliver()
            deliveryChecks.insert(kind)
            print("UPDATE_RECOVERY_MODEL_OK: kind=\(kind) currentRemaining=50 consumptionClaim=false")
        }
    }

    private func prepareRecoveryNotice() throws -> RefreshNotice? {
        let base = Date().addingTimeInterval(-30), reset = base.addingTimeInterval(3600)
        try seedNoticeFixture(at: base, reset: reset)
        try readNoticeFixture(remaining: 55, at: base.addingTimeInterval(1), reset: reset)
        model.setNoticeFailureFixture(.disconnected, at: base.addingTimeInterval(2))
        check(model.refreshNotice == nil && !deliveryQueue.isPending, "transport failure clears pending model notice")
        let readAt = base.addingTimeInterval(3)
        try readNoticeFixture(remaining: 50, at: readAt, reset: reset)
        let deliverAt = readAt.addingTimeInterval(11)
        check(deliveryQueue.candidate(at: deliverAt, blocked: true) == nil && deliveryQueue.isPending,
            "recovery model event survives eleven seconds of ordinary suppression")
        recoveryReadAt = deliverAt.addingTimeInterval(1); recoveryResetAt = reset
        return deliveryQueue.candidate(at: deliverAt, blocked: false)
    }

    private func verifyUnchangedActive(_ island: IslandPanelController) {
        guard let readAt = recoveryReadAt, let reset = recoveryResetAt, let activeNotice,
            let armed = island.smokeNoticeArmedAt, let painted = island.smokeNoticePaintReadyAt else {
            check(false, "unchanged active test lacks recovery/paint operands"); return
        }
        let before = noticePublications, deadline = armed + activeNotice.holdDuration
        do { try readNoticeFixture(remaining: 50, at: readAt, reset: reset) }
        catch { check(false, "unchanged active model fixture failed error=\(error)"); return }
        check(noticePublications == before && model.refreshNotice?.id == activeNotice.id
            && island.smokeNoticeID == activeNotice.id && island.smokeNoticeTargetActive
            && island.smokeNoticeArmedAt == armed && island.smokeNoticePaintReadyAt == painted
            && island.paintReceipt?.frame.noticeID == activeNotice.id && !deliveryQueue.isPending,
            "unchanged active publication preserves ID/paint/expiry publications=\(noticePublications-before) expectedID=\(activeNotice.id) actualID=\(String(describing: island.smokeNoticeID)) armedBefore=\(armed) armedAfter=\(String(describing: island.smokeNoticeArmedAt)) paintBefore=\(painted) paintAfter=\(String(describing: island.smokeNoticePaintReadyAt)) deadline=\(deadline)")
        originalNoticeDeadline = deadline; unchangedActiveVerified = passed
    }

    private func startScenario() {
        controller?.stop()
        guard let geometry else { finish(false); return }
        targetReachedAt = nil; closingAt = nil; targetVerified = false; oldDeadlineVerified = false
        noticePaintReadyAt = nil; noticeArmedAt = nil; originalNoticeDeadline = nil
        longDwellPointerSamples = 0; longDwellSettingChanged = false; longDwellDuplicateChecks = 0
        longReadinessDelayVerified = false
        lastSampleCount = 0; activeNotice = nil; retainsNoticeWhileClosing = false
        let creationStarted = CACurrentMediaTime()
        model.setUpdateFixture(fixtures[scenario.fixtureIndex].snapshot)
        model.noticeDuration = scenario.duration
        scenarioCreatedAt = CACurrentMediaTime()
        controller = IslandPanelController(model: model, geometry: geometry, startPolling: false,
            reducedMotionOverride: reduced, motionSample: { [weak self] sample in self?.observe(sample) },
            hovered: {}, refresh: {}, settings: {}, quit: {})
        next(.idle, at: creationStarted)
        SmokeDiagnostics.mark("update scenario=\(scenario.rawValue) actualBacking=\(controller?.panel.backingScaleFactor ?? 0) syntheticCutout=true reducedMotion=\(reduced)")
    }

    private func observe(_ sample: IslandMotionSample) {
        guard let island = controller, !finished else { return }
        totalSamples += 1; lastSampleCount += 1
        if island.smokeNoticeTargetActive && sample.progress == island.geometry.updateProgress && targetReachedAt == nil {
            targetReachedAt = sample.observed
        }
    }

    private func show(_ notice: RefreshNotice, at now: TimeInterval) {
        guard let island = controller else { finish(false); return }
        activeNotice = notice; shownAt = now; targetReachedAt = nil; closingAt = nil; targetVerified = false
        noticePaintReadyAt = nil; noticeArmedAt = nil
        check(notice.isEligible && notice.holdDuration == scenario.duration.seconds,
            "delivery captures selected duration seconds=\(notice.holdDuration)")
        if scenario == .longDwell { island.smokeDelayNoticeReadiness(seconds: 1.2) }
        check(island.showRefreshNotice(notice), "notice accepted from collapsed or passive state")
        check(island.smokeNoticeVisible && island.smokeNoticeTargetActive && !island.isInteracting
            && island.smokeTargetProgress == island.geometry.updateProgress
            && island.panel.ignoresMouseEvents, "notice targets intermediate click-through state")
        if reduced {
            targetReachedAt = now
            check(island.smokeProgress == island.geometry.updateProgress && island.smokeVelocity == 0
                && !island.smokeMotionRunning, "Reduce Motion snaps immediately without a motion source")
        } else {
            check(island.smokeNoticeArmedAt == nil && island.smokeNoticePaintReadyAt == nil,
                "opening animation cannot start notice dwell before settled paint")
        }
        // The long case changes its setting during the actual painted hold.
        if scenario != .longDwell { changeDurationForFutureNotices(to: notice.duration == .long ? .short : .long) }
        next(.opening, at: now)
    }

    private func changeDurationForFutureNotices(to duration: NoticeDuration) {
        model.noticeDuration = duration
        let future = makeNotice(for: fixtures[scenario.fixtureIndex], duration: model.noticeDuration)
        check(activeNotice?.duration == scenario.duration && future?.duration == model.noticeDuration
            && future?.holdDuration != activeNotice?.holdDuration && preferencesUnchanged,
            "setting change affects future notices without changing active duration or writing defaults")
    }

    private func rejectNotice(for fixture: Fixture, island: IslandPanelController, at now: TimeInterval) {
        check(makeNotice(for: fixture, duration: model.noticeDuration) == nil,
            "ineligible \(fixture.name) factory returns nil")
        let notice = candidate(for: fixture, duration: model.noticeDuration)
        let before = (island.smokeProgress, island.smokeVelocity, island.panel.frame, island.smokeNoticeID)
        check(!notice.isEligible && !island.showRefreshNotice(notice)
            && island.smokeProgress == before.0 && island.smokeVelocity == before.1
            && island.panel.frame == before.2 && island.smokeNoticeID == before.3,
            "controller rejects \(fixture.name) without showing or moving")
        next(.rejected, at: now)
    }

    private func captureReadiness(_ island: IslandPanelController, after receipt: TimeInterval) -> Bool {
        guard let painted = island.smokeNoticePaintReadyAt, let armed = island.smokeNoticeArmedAt,
              let paint = island.paintReceipt else { return false }
        let probe = island.motionProbe, expected = island.geometry.frame(progress: island.geometry.updateProgress)
        // The view observation now includes notice identity. Both callbacks must be
        // fresh for this delivery, but view acknowledgement and Canvas paint may race.
        guard probe.renderedAt >= receipt else { return false }
        check(painted >= receipt && armed >= painted && armed <= probe.observed
            && island.smokeNoticeID == activeNotice?.id && island.smokeNoticeTargetActive
            && island.smokeProgress == island.geometry.updateProgress && !island.smokeMotionRunning
            && paint.observed >= painted && paint.frame.noticeID == activeNotice?.id
            && paint.frame.progress == island.geometry.updateProgress
            && paint.frame.viewport == expected.size && paint.actualViewport == expected.size
            && probe.renderedProgress == island.geometry.updateProgress && probe.renderedAt >= receipt
            && probe.frame == expected && probe.viewport == expected.size,
            "fresh matching settled native paint precedes expiry arm receipt=\(receipt) paint=\(painted) armed=\(armed)")
        noticePaintReadyAt = painted; noticeArmedAt = armed
        if scenario == .longDwell {
            check(longReadinessDelayVerified && armed - receipt >= 1.2,
                "six-second notice survives delayed readiness before its actual paint receipt arms expiry")
            originalNoticeDeadline = armed + (activeNotice?.holdDuration ?? 6)
        }
        return passed
    }

    @objc private func tick(_ sender: Timer) {
        guard sender === timer, !finished, let island = controller else { return }
        let now = CACurrentMediaTime(), elapsed = now - phaseStarted
        // Motion phases keep their original tight watchdog. Only a real configured
        // dwell gets a longer phase allowance; the six-second case is never sped up.
        let phaseLimit: TimeInterval
        switch phase {
        case .holding: phaseLimit = (activeNotice?.holdDuration ?? 6) + 0.9
        case .replacementHold: phaseLimit = (activeNotice?.holdDuration ?? 6) + 1.1
        default: phaseLimit = 4.5
        }
        guard now - startedAt < 75, elapsed < phaseLimit else {
            SmokeDiagnostics.mark("update deadline scenario=\(scenario.rawValue) phase=\(phase.rawValue) elapsed=\(elapsed) total=\(now-startedAt)")
            finish(false); return
        }
        guard passed else { finish(false); return }
        if phase != .stopped {
            guard nativeFrameValid(island) else { check(false, "native frame/top-edge/nonactivation invariant"); finish(false); return }
        }
        if scenario == .longDwell, (phase == .opening || phase == .holding),
           island.smokeNoticeTargetActive {
            verifyLongNoticePointer(island)
        }
        switch phase {
        case .idle where elapsed >= 0.14:
            check(settledNative(island, progress: 0, after: scenarioCreatedAt), "normal-run-loop collapsed viewport")
            let fixture = fixtures[scenario.fixtureIndex]
            model.setUpdateFixture(fixture.snapshot)
            if scenario.rejectsNotice {
                rejectNotice(for: fixture, island: island, at: now)
            } else if scenario == .recoveryDwell {
                do {
                    guard let notice = try prepareRecoveryNotice() else {
                        check(false, "recovery queue must return an eligible model event"); return
                    }
                    show(notice, at: now)
                    guard passed else { finish(false); return }
                    deliveryQueue.didDeliver()
                    check(!deliveryQueue.isPending && deliveryQueue.candidate(at: recoveryReadAt ?? Date(), blocked: false) == nil,
                        "painted recovery consumes shared queue exactly once")
                } catch { check(false, "painted recovery model fixture failed error=\(error)") }
            } else if let notice = makeNotice(for: fixture, duration: model.noticeDuration) {
                show(notice, at: now)
            } else { check(false, "changed numeric fixture must produce a factory notice") }
        case .rejected:
            check(!island.smokeNoticeVisible && !island.smokeNoticeTargetActive && !island.smokeMotionRunning
                && island.smokeProgress == 0 && island.smokeVelocity == 0 && island.smokeTargetProgress == 0
                && island.smokeNoticeArmedAt == nil && island.smokeNoticePaintReadyAt == nil
                && island.panel.ignoresMouseEvents && !island.isInteracting,
                "ineligible read stays idle without content, motion, or expiry")
            if elapsed >= 0.16 {
                check(settledNative(island, progress: 0, after: scenarioCreatedAt), "rejected read preserves native idle viewport")
                rejectedChecks += 1
                print("UPDATE_REJECT_OK: kind=\(scenario.rawValue)")
                advanceScenario()
            }
        case .opening:
            if island.smokeProgress != island.geometry.updateProgress || island.smokeMotionRunning {
                check(island.smokeNoticeArmedAt == nil && island.smokeNoticePaintReadyAt == nil,
                    "unsettled target has no armed expiry or ready paint")
            }
            if scenario == .longDwell, now - shownAt >= 0.8, island.smokeNoticeArmedAt == nil {
                check(island.smokeNoticeVisible && island.smokeNoticeTargetActive
                    && island.smokeNoticePaintReadyAt == nil && island.smokeNoticeID == activeNotice?.id
                    && island.smokeTargetProgress == island.geometry.updateProgress && !island.isInteracting,
                    "readiness beyond the former quarter-second cutoff keeps notice pending without starting dwell")
                longReadinessDelayVerified = true
            }
            if scenario == .movingPromotion, island.smokeProgress > 0.02,
                island.smokeProgress < island.geometry.updateProgress, island.smokeVelocity > 0 {
                promoteWhileMoving(island, at: now)
            } else if island.smokeProgress == island.geometry.updateProgress && !island.smokeMotionRunning,
                captureReadiness(island, after: shownAt) {
                if targetReachedAt == nil { targetReachedAt = now }
                next(.holding, at: now)
            }
        case .holding:
            guard let armed = noticeArmedAt, let painted = noticePaintReadyAt, let activeNotice else { finish(false); return }
            let held = now - armed, paintedFor = now - painted
            let hold = activeNotice.holdDuration
            if scenario == .longDwell, island.smokeNoticeTargetActive {
                if held >= 1 && !longDwellSettingChanged {
                    changeDurationForFutureNotices(to: .short)
                    check(activeNotice.duration == .long && activeNotice.holdDuration == 6
                        && island.smokeNoticeID == activeNotice.id
                        && island.smokeNoticeArmedAt == armed && island.smokeNoticePaintReadyAt == painted
                        && originalNoticeDeadline == armed + 6,
                        "changing six-second notice setting after paint leaves its original expiry intact")
                    longDwellSettingChanged = true
                }
                if longDwellDuplicateChecks < 2, held >= Double(longDwellDuplicateChecks + 1) * 2 {
                    let before = (island.smokeProgress, island.smokeVelocity, island.panel.frame)
                    check(island.showRefreshNotice(activeNotice) && island.smokeNoticeTargetActive
                        && island.smokeNoticeID == activeNotice.id && island.smokeNoticeArmedAt == armed
                        && island.smokeNoticePaintReadyAt == painted && originalNoticeDeadline == armed + 6
                        && island.smokeProgress == before.0 && island.smokeVelocity == before.1
                        && island.panel.frame == before.2,
                        "replaying identical six-second notice preserves paint, motion and original expiry")
                    longDwellDuplicateChecks += 1
                }
            }
            if island.smokeNoticeTargetActive,
                island.smokeNoticeArmedAt != armed || island.smokeNoticePaintReadyAt != painted {
                check(false, "active notice changed its captured paint or expiry deadline")
            }
            if !targetVerified, elapsed >= 0.14 {
                check(settledNative(island, progress: island.geometry.updateProgress, after: shownAt)
                    && island.panel.ignoresMouseEvents && !island.smokeTargetExpanded
                    && island.smokeNoticeVisible && island.smokeNoticeTargetActive,
                    "normal-run-loop intermediate viewport retains notice and passive routing")
                if !reduced { check(lastSampleCount >= 3, "real spring callbacks reached intermediate target") }
                if scenario == .standardDwell { rejectIneligibleWhileActive(island) }
                if scenario == .recoveryDwell { verifyUnchangedActive(island) }
                targetVerified = true
            }
            if scenario == .coalescing, targetVerified, held >= 0.65 {
                replaceNotice(island, at: now); return
            }
            if scenario == .armedPromotion, targetVerified, held >= 0.35 {
                promoteArmed(island, at: now); return
            }
            if scenario == .retiredTimer, targetVerified, held >= 0.35 {
                let before = (island.smokeProgress, island.smokeVelocity, island.panel.frame, island.smokeNoticeID)
                check(island.verifyRetiredNoticeIsInert(), "retired real expiry callback is inert")
                island.collapse(); island.beginSmokeExpansion()
                guard let laterNotice = makeNotice(for: fixtures[1], duration: .short) else { finish(false); return }
                let accepted = island.showRefreshNotice(laterNotice)
                check(!accepted && island.smokeStopped && island.smokeProgress == before.0
                    && island.smokeVelocity == before.1 && island.panel.frame == before.2
                    && island.smokeNoticeID == before.3, "stopped controller rejects later show/collapse/expansion actions")
                next(.stopped, at: now); return
            }
            if !island.smokeNoticeTargetActive {
                check(targetVerified && held >= hold - 0.05 && held <= hold + 0.75 && paintedFor >= hold - 0.05,
                    "automatic expiry waits full configured painted dwell armed=\(held) painted=\(paintedFor) seconds=\(hold)")
                if scenario == .shortDwell || scenario == .standardDwell || scenario == .longDwell {
                    completedDwells.insert(activeNotice.duration)
                    print("UPDATE_DWELL_OK: seconds=\(Int(hold)) armedHeld=\(held) paintHeld=\(paintedFor)")
                }
                if scenario == .longDwell {
                    check(longDwellPointerSamples >= 100 && longDwellSettingChanged && longDwellDuplicateChecks == 2
                        && longReadinessDelayVerified
                        && model.noticeDuration == .short && activeNotice.duration == .long && hold == 6
                        && held >= 6 && paintedFor >= 6 && originalNoticeDeadline == armed + 6
                        && !island.isInteracting && island.smokeTargetProgress == 0,
                        "six-second painted hold survives adjacent pointer churn, a shorter future setting and repeated identical notices")
                    longDwellVerified = passed
                    print("UPDATE_POINTER_DWELL_OK: seconds=6 held=\(held) adjacent=true settingsCaptured=true repeatedID=true delayedReadiness=true")
                }
                if scenario == .secondaryChanged {
                    secondaryVerified = activeNotice.window?.id == "codex:secondary"
                    check(secondaryVerified, "changed secondary completed its own passive notice dwell")
                    print("UPDATE_SECONDARY_OK: unchanged primary did not mask numeric secondary change")
                }
                if scenario == .identityFreeChange || scenario == .metadataFreeChange {
                    let reason: QuotaUpdateReason = scenario == .identityFreeChange ? .identityUnavailable : .dataUnavailable
                    check(activeNotice.isEligible && activeNotice.change == .updated(reason: reason)
                        && activeNotice.title == "额度已更新" && activeNotice.window?.remainingPercent == 79.875
                        && activeNotice.result.previousFetchedAt == nil,
                        "generic changed-value notice completed actual painted dwell without consumption claim")
                    genericVerified.insert(scenario.rawValue)
                    print("UPDATE_GENERIC_OK: kind=\(scenario.rawValue) currentRemaining=79.875 consumptionClaim=false")
                }
                if scenario == .recoveryDwell {
                    check(unchangedActiveVerified && originalNoticeDeadline == armed + hold
                        && hold == 6 && held >= hold && paintedFor >= hold
                        && activeNotice.isEligible && activeNotice.change == .updated(reason: .previousReadFailed)
                        && activeNotice.window?.remainingPercent == 50 && activeNotice.result.previousFetchedAt == nil
                        && activeNotice.title == "额度已更新" && activeNotice.detail.contains("未计算")
                        && !activeNotice.detail.contains("减少") && !deliveryQueue.isPending,
                        "generic recovery completes real painted dwell at its unchanged original deadline expected=\(String(describing: originalNoticeDeadline)) actual=\(armed+hold) current=\(String(describing: activeNotice.window?.remainingPercent)) detail=\(activeNotice.detail)")
                    recoveryPaintVerified = passed
                    print("UPDATE_RECOVERY_PAINT_OK: reason=previousReadFailed currentRemaining=50 consumptionClaim=false blockedSeconds=11 armedHeld=\(held) paintHeld=\(paintedFor)")
                    print("UPDATE_UNCHANGED_ACTIVE_OK: publications=0 sameID=true samePaint=true sameDeadline=true armedHeld=\(held) paintHeld=\(paintedFor)")
                }
                // Expiry can snap and paint before this inspection callback runs.
                // Require freshness after the actual scheduled deadline, not after
                // the later observation of that already-completed transition.
                closingAt = armed + hold; retainsNoticeWhileClosing = !reduced
                if reduced {
                    check(island.smokeProgress == 0 && !island.smokeMotionRunning && !island.smokeNoticeVisible,
                        "Reduce Motion expires with immediate idle snap and cleared content")
                } else if island.smokeProgress > 0 {
                    check(island.smokeNoticeVisible && island.smokeTargetProgress == 0,
                        "notice remains during continuous closing fade")
                }
                next(.closing, at: now)
            } else if held > hold + 0.75 { check(false, "notice expiry failed to fire within bounded hold") }
        case .closing:
            if island.smokeProgress > 0 {
                check((!retainsNoticeWhileClosing || island.smokeNoticeVisible) && island.panel.ignoresMouseEvents,
                    "closing content remains passive until idle")
            } else if !island.smokeMotionRunning { next(.closed, at: now) }
        case .closed where elapsed >= 0.14:
            check(settledNative(island, progress: 0, after: closingAt ?? phaseStarted)
                && !island.smokeNoticeVisible && !island.smokeNoticeTargetActive && !island.isInteracting
                && island.panel.ignoresMouseEvents, "settled idle clears transient content and timers")
            advanceScenario()
        case .expanded where island.smokeProgress == 1 && !island.smokeMotionRunning:
            next(.promotedHold, at: now)
        case .promotedHold:
            if !targetVerified, elapsed >= 0.14 {
                verifyExpanded(island, after: shownAt)
                check(!island.smokeNoticeVisible && !island.smokeNoticeTargetActive,
                    "full promotion retires notice presentation")
                check(island.smokeNoticeArmedAt == nil && island.smokeNoticePaintReadyAt == nil,
                    "explicit dismissal before expansion retires the notice paint and expiry identity")
                targetVerified = true
            }
            if elapsed >= 2.20 {
                check(targetVerified && island.smokeTargetExpanded && island.smokeProgress == 1
                    && !island.smokeMotionRunning && island.isInteracting
                    && (originalNoticeDeadline.map { now > $0 + 0.15 } ?? false),
                    "explicitly requested expansion survives the dismissed notice deadline")
                if scenario == .movingPromotion, let geometry {
                    check(island.geometry == geometry, "content-fit change remains deferred throughout open interaction")
                }
                island.collapse(); closingAt = now
                next(scenario == .movingPromotion ? .refitClosing : .closing, at: now)
            }
        case .refitClosing where island.smokeProgress == 0 && !island.smokeMotionRunning:
            guard let refittedGeometry else { finish(false); return }
            check(island.geometry == refittedGeometry, "deferred content-fit endpoint adopted at idle")
            next(.refitOpening, at: now)
        case .refitOpening where elapsed >= 0.14:
            check(settledNative(island, progress: 0, after: closingAt ?? phaseStarted), "refit preserves idle anchor and viewport")
            island.beginSmokeExpansion(); shownAt = now; next(.refitExpanded, at: now)
        case .refitExpanded where island.smokeProgress == 1 && !island.smokeMotionRunning:
            next(.refitSettled, at: now)
        case .refitSettled where elapsed >= 0.14:
            verifyExpanded(island, after: shownAt)
            guard var expected = refittedGeometry else { finish(false); return }
            // This fresh idle-to-hover cycle uses the ordinary width profile.
            // Preserve exact equality for every other field, including no handoff override.
            expected.ordinaryHoverWidth = true
            check(island.geometry == expected, "next expansion uses new content-fit height")
            island.collapse(); closingAt = now; next(.closing, at: now)
        case .replacementHold:
            verifyReplacement(island, at: now)
        case .stopped where elapsed >= 0.14:
            check(island.smokeStopped && !island.smokeMotionRunning && island.panel.ignoresMouseEvents,
                "retired controller remains stopped after normal-run-loop dwell")
            advanceScenario()
        default: break
        }
    }

    /// Adjacent global samples straddle the actual shell bottom by only two points.
    /// They exercise the ordinary pointer path, never the expansion helper.
    private func verifyNoticePointerProtected(_ island: IslandPanelController, inside: Bool) {
        let progress = island.smokeProgress, frame = island.geometry.frame(progress: progress)
        let contour = island.geometry.contourRect(progress: progress)
        let point = CGPoint(x: frame.minX + contour.midX,
                            y: frame.maxY - contour.maxY + (inside ? 1 : -1))
        let before = (island.smokeProgress, island.smokeVelocity, island.panel.frame)
        let noticeID = island.smokeNoticeID, armed = island.smokeNoticeArmedAt
        let painted = island.smokeNoticePaintReadyAt, retarget = island.smokeRetarget?.eventTime
        check(island.geometry.hoverContains(point, progress: progress) == inside,
            "adjacent notice pointer is on the intended side of the actual shell boundary")
        island.smokePointer(at: point, now: ProcessInfo.processInfo.systemUptime)
        check(island.smokeNoticeTargetActive && island.smokeNoticeVisible && island.smokeNoticeID == noticeID
            && island.smokeExpansionOwner == .quotaNotice && !island.isInteracting && !island.smokeTargetExpanded
            && island.smokeTargetProgress == island.geometry.updateProgress && island.panel.ignoresMouseEvents
            && island.smokeNoticeArmedAt == armed && island.smokeNoticePaintReadyAt == painted
            && island.smokeRetarget?.eventTime == retarget && island.smokeProgress == before.0
            && island.smokeVelocity == before.1 && island.panel.frame == before.2,
            "ordinary adjacent pointer cannot dismiss, promote, move or rearm an active notice")
    }

    private func verifyLongNoticePointer(_ island: IslandPanelController) {
        verifyNoticePointerProtected(island, inside: longDwellPointerSamples.isMultiple(of: 2))
        longDwellPointerSamples += 1
    }

    private func exitStableShellAfterDismissal(_ island: IslandPanelController) {
        let frame = island.geometry.frame(progress: 1)
        let contour = island.geometry.contourRect(progress: 1)
        let point = CGPoint(x: frame.minX + contour.midX, y: frame.maxY - contour.maxY - 5)
        check(!island.geometry.hoverContains(point, progress: 1),
            "explicit dismissal is followed by an adjacent exit from the stable full shell")
        island.smokePointer(at: point, now: ProcessInfo.processInfo.systemUptime)
    }

    private func retargetPreservesSpring(_ island: IslandPanelController,
        before: (Double, Double), previousTarget: Double) -> Bool {
        island.smokeRetarget.map { event in
            var expected = event.before
            expected.advance(target: previousTarget, elapsed: event.consumedElapsed, reduceMotion: false)
            return event.before.progress == before.0 && event.before.velocity == before.1
                && abs(expected.progress - event.integrated.progress) < 1e-12
                && abs(expected.velocity - event.integrated.velocity) < 1e-12
                && abs(island.smokeProgress - event.integrated.progress) < 1e-12
                && abs(island.smokeVelocity - event.integrated.velocity) < 1e-12
        } ?? false
    }

    private func promoteWhileMoving(_ island: IslandPanelController, at now: TimeInterval) {
        originalNoticeDeadline = now + (activeNotice?.holdDuration ?? 2)
        verifyNoticePointerProtected(island, inside: true)
        verifyNoticePointerProtected(island, inside: false)
        let before = (island.smokeProgress, island.smokeVelocity)
        let previousTarget = island.smokeTargetProgress
        island.dismissRefreshNotice()
        check(retargetPreservesSpring(island, before: before, previousTarget: previousTarget)
            && !island.smokeNoticeTargetActive && island.smokeTargetProgress == 0,
            "explicit dismissal preserves moving notice spring state before requesting details")
        exitStableShellAfterDismissal(island)
        let beforeExpansion = (island.smokeProgress, island.smokeVelocity)
        let dismissedTarget = island.smokeTargetProgress
        check(island.beginSmokeExpansion(), "explicit expansion is accepted only after dismissal and stable-shell exit")
        check(retargetPreservesSpring(island, before: beforeExpansion, previousTarget: dismissedTarget)
            && island.smokeVelocity > 0 && island.smokeTargetExpanded && island.smokeTargetProgress == 1
            && !island.smokeNoticeTargetActive,
            "explicit expansion after dismissal preserves position and velocity instead of resetting the spring")
        let promoted = (island.smokeProgress, island.smokeVelocity)
        island.beginSmokeExpansion()
        check(island.smokeProgress == promoted.0 && island.smokeVelocity == promoted.1,
            "repeated expansion request preserves current spring state")
        if let refittedGeometry, let geometry {
            let frame = island.panel.frame
            island.updateGeometry(refittedGeometry)
            check(island.geometry == geometry && island.panel.frame == frame
                && island.smokeProgress == promoted.0 && island.smokeVelocity == promoted.1,
                "content-fit update is deferred while opening")
        } else { check(false, "missing refit fixture") }
        targetVerified = false; shownAt = now; next(.expanded, at: now)
    }

    private func rejectIneligibleWhileActive(_ island: IslandPanelController) {
        let before = (island.smokeProgress, island.smokeVelocity, island.panel.frame, island.smokeNoticeID)
        let armed = island.smokeNoticeArmedAt, painted = island.smokeNoticePaintReadyAt
        for index in [0, 2, 3] {
            let notice = candidate(for: fixtures[index], duration: .long)
            check(!island.showRefreshNotice(notice) && island.smokeNoticeTargetActive
                && island.smokeProgress == before.0 && island.smokeVelocity == before.1
                && island.panel.frame == before.2 && island.smokeNoticeID == before.3
                && island.smokeNoticeArmedAt == armed && island.smokeNoticePaintReadyAt == painted,
                "rejected \(fixtures[index].name) cannot replace or rearm an active notice")
        }
    }

    private func promoteArmed(_ island: IslandPanelController, at now: TimeInterval) {
        guard let armed = noticeArmedAt, let activeNotice else { finish(false); return }
        originalNoticeDeadline = armed + activeNotice.holdDuration
        verifyNoticePointerProtected(island, inside: true)
        verifyNoticePointerProtected(island, inside: false)
        island.dismissRefreshNotice()
        check(!island.smokeNoticeTargetActive && island.smokeNoticeArmedAt == nil
            && island.smokeNoticePaintReadyAt == nil, "explicit dismissal cancels the armed expiry")
        exitStableShellAfterDismissal(island)
        let before = (island.smokeProgress, island.smokeVelocity)
        let previousTarget = island.smokeTargetProgress
        check(island.beginSmokeExpansion(), "explicit details request follows dismissal of the armed notice")
        check(island.smokeTargetExpanded && island.smokeTargetProgress == 1 && !island.smokeNoticeTargetActive
            && retargetPreservesSpring(island, before: before, previousTarget: previousTarget),
            "explicit expansion after dismissal preserves the former notice spring without a reset")
        targetVerified = false; shownAt = now; next(.expanded, at: now)
    }

    private func replaceNotice(_ island: IslandPanelController, at now: TimeInterval) {
        guard let activeNotice, let armed = noticeArmedAt, let painted = noticePaintReadyAt else { finish(false); return }
        let before = (island.smokeProgress, island.smokeVelocity, island.panel.frame)
        originalNoticeDeadline = armed + activeNotice.holdDuration
        check(island.showRefreshNotice(activeNotice) && island.smokeNoticeArmedAt == armed
            && island.smokeNoticePaintReadyAt == painted,
            "same-ID notice coalesces without restarting its paint or expiry deadline")
        model.noticeDuration = .long
        guard let replacement = makeNotice(for: fixtures[1], duration: model.noticeDuration) else { finish(false); return }
        check(replacement.id != activeNotice.id && replacement.holdDuration == 6
            && island.showRefreshNotice(replacement), "newer notice captures its own changed six-second setting")
        self.activeNotice = replacement; replacedAt = now
        noticeArmedAt = nil; noticePaintReadyAt = nil
        check(island.smokeNoticeID == replacement.id && island.smokeNoticeTargetActive
            && island.smokeProgress == before.0 && island.smokeVelocity == before.1
            && island.panel.frame == before.2 && island.panel.ignoresMouseEvents,
            "repeat and newer notice coalesce with unchanged position/velocity")
        next(.replacementHold, at: now)
    }

    private func verifyReplacement(_ island: IslandPanelController, at now: TimeInterval) {
        guard let activeNotice, let originalNoticeDeadline else { finish(false); return }
        if noticeArmedAt == nil {
            if !captureReadiness(island, after: replacedAt) {
                if now - replacedAt > 0.75 { check(false, "replacement never received fresh settled paint and expiry arm") }
                return
            }
        }
        guard let armed = noticeArmedAt, let painted = noticePaintReadyAt else { finish(false); return }
        let held = now - armed, paintedFor = now - painted, hold = activeNotice.holdDuration
        if held >= 1 && model.noticeDuration != .short {
            model.noticeDuration = .short
            check(activeNotice.duration == .long && hold == 6 && preferencesUnchanged,
                "replacement keeps six seconds when the future-notice setting changes mid-hold to two")
        }
        if island.smokeNoticeTargetActive,
            island.smokeNoticeArmedAt != armed || island.smokeNoticePaintReadyAt != painted {
            check(false, "replacement changed its captured paint or expiry deadline")
        }
        if now >= originalNoticeDeadline + 0.15 && held < hold - 0.15 && !oldDeadlineVerified {
            check(island.smokeNoticeTargetActive && island.smokeNoticeID == activeNotice.id
                && island.smokeProgress == island.geometry.updateProgress && island.panel.ignoresMouseEvents,
                "superseded two-second timer cannot dismiss newer six-second notice")
            oldDeadlineVerified = true
        }
        if !island.smokeNoticeTargetActive {
            check(oldDeadlineVerified && model.noticeDuration == .short && hold == 6
                && held >= hold && held <= hold + 0.75 && paintedFor >= hold,
                "replacement receives its own full painted hold armed=\(held) painted=\(paintedFor) seconds=\(hold)")
            print("UPDATE_REPLACEMENT_DWELL_OK: seconds=6 held=\(held) settingsCaptured=true oldTimerIgnored=true")
            closingAt = armed + hold; retainsNoticeWhileClosing = true; next(.closing, at: now)
        } else if held > hold + 0.75 { check(false, "replacement expiry did not retire") }
    }

    private func nativeFrameValid(_ island: IslandPanelController) -> Bool {
        let probe = island.motionProbe, expected = island.geometry.frame(progress: island.smokeProgress)
        nativeProbes += 1
        return probe.visible && probe.nonKey && NSApp.keyWindow === initialKey && island.placementIsValid
            && probe.frame == expected && abs(probe.frame.maxY - screen.frame.maxY) < 0.001
            && probe.contentBounds == CGRect(origin: .zero, size: probe.frame.size)
            && island.smokeProgress.isFinite && island.smokeVelocity.isFinite
    }

    private func settledNative(_ island: IslandPanelController, progress: Double, after: TimeInterval) -> Bool {
        let probe = island.motionProbe, expected = island.geometry.frame(progress: progress)
        let valid = nativeFrameValid(island) && !probe.running && probe.requestedProgress == progress
            && probe.renderedProgress == progress && probe.renderedAt >= after
            && probe.frame == expected && probe.viewport == expected.size
            && probe.layerPresentation == CGRect(origin: .zero, size: expected.size)
        SmokeDiagnostics.mark("update normal-runloop scenario=\(scenario.rawValue) progress=\(progress) frame=\(probe.frame) viewport=\(probe.viewport) rendered=\(probe.renderedProgress) renderedAt=\(probe.renderedAt) presentation=\(String(describing: probe.layerPresentation)) valid=\(valid)")
        return valid
    }

    private func verifyExpanded(_ island: IslandPanelController, after: TimeInterval) {
        // These checks use the measured SwiftUI Quit preference after a real run-loop
        // dwell, never layoutSubtreeIfNeeded or a forced bitmap layout.
        check(settledNative(island, progress: 1, after: after)
            && island.verifyExpandedLayout(includePixels: false) && island.verifySmokeClickRouting(),
            "expanded native viewport and measured Quit visibility/routing")
        expandedChecks += 1
    }

    private func check(_ value: Bool, _ label: String) {
        passed = value && passed
        SmokeDiagnostics.mark("update \(label) valid=\(value)")
        if !value { print("UPDATE_ASSERT_FAILED: \(label)") }
    }
    private func next(_ phase: Phase, at now: TimeInterval) { self.phase = phase; phaseStarted = now }
    private func advanceScenario() {
        scenarioIndex += 1
        if scenarioIndex < Scenario.allCases.count { startScenario() }
        else {
            finish(passed && totalSamples >= 20 && nativeProbes >= 20 && expandedChecks == 3
                && rejectedChecks == 3 && completedDwells == Set(NoticeDuration.allCases) && secondaryVerified
                && genericVerified == Set(["identityFreeChange", "metadataFreeChange"])
                && unchangedActiveVerified && recoveryPaintVerified && longDwellVerified
                && deliveryChecks == Set(["hover", "menu", "settings", "newest", "accountSwitch", "failure", "disabled",
                    "receivedExpired", "fetchedExpired", "resetDue", "receivedFuture", "fetchedFuture", "ageBoundary",
                    "timedOut", "disconnected", "longGap"]))
        }
    }

    private func noticePreferences() -> [String: Any] {
        ["refreshNoticesEnabled", "noticeDuration"].reduce(into: [:]) { values, key in
            if let value = UserDefaults.standard.object(forKey: key) { values[key] = value }
        }
    }

    private var preferencesUnchanged: Bool {
        guard let savedPreferences else { return true }
        return NSDictionary(dictionary: noticePreferences()).isEqual(NSDictionary(dictionary: savedPreferences))
    }

    private func finish(_ valid: Bool) {
        guard !finished else { return }
        finished = true; stop()
        let result = valid && passed
        SmokeDiagnostics.mark("update samples=\(totalSamples) nativeProbes=\(nativeProbes) expandedQuitChecks=\(expandedChecks) elapsed=\(CACurrentMediaTime()-startedAt) scanout=false physicalFeelUnverified=true")
        print(result ? "UPDATE_OK: numeric-only eligibility, actual 2/4/6-second painted dwell, protected adjacent pointer dwell, delayed paint readiness, shared queue/model delivery, generic recovery, unchanged active dwell, settings safety, explicit dismissal and expansion, coalescing, reduced motion, content fit and retired callbacks passed" : "UPDATE_FAILED: native update-pill contract failed")
        completion(result)
    }
    func stop() {
        timer?.invalidate(); timer = nil; controller?.stop()
        noticeSubscription?.cancel(); noticeSubscription = nil
        settingSubscription?.cancel(); settingSubscription = nil
        deliveryQueue.invalidate()
        if let originalNoticeSetting, let originalDurationSetting {
            model.refreshNoticesEnabled = originalNoticeSetting; model.noticeDuration = originalDurationSetting
            let restored = model.refreshNoticesEnabled == originalNoticeSetting
                && model.noticeDuration == originalDurationSetting && preferencesUnchanged
            check(restored, "native fixture restores model settings and preserves stored preferences")
            if restored { print("UPDATE_SETTINGS_OK: model restored and persisted preferences untouched") }
            self.originalNoticeSetting = nil; self.originalDurationSetting = nil; savedPreferences = nil
        }
    }
}
#endif
