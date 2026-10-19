#if os(macOS)
import AppKit
import CryptoKit
import QuartzCore
import NotchCore

/// The identical file is compiled against the untouched v1.0.0 production tree
/// and the candidate. Only APIs already present in v1.0.0 are used here.
/// This compares native animation after controller-level, fixed-coordinate
/// inputs. It does not replace the candidate's real NSApplication ingress gate.
@MainActor
final class BaselineMotionComparisonHarness: NSObject {
    private struct Failure: Error { let message: String }
    private struct Step {
        let time: TimeInterval
        let kind: String
        let value: String
    }
    private struct Transition {
        let started: TimeInterval
        let target: Double
        let owner: String
        let inputIndex: Int
    }
    private let screen: NSScreen
    private let completion: (Bool) -> Void
    private let reader = BaselineComparisonReader()
    private var controller: MusicLyricsController?
    private var model: MeterModel?
    private var panel: IslandPanelController?
    private var task: Task<Void, Never>?
    private var observer: Timer?
    private var watchdog: Timer?
    private var started = false
    private var finished = false
    private var collectingTimedEvidence = true
    private var timedElapsed: TimeInterval?
    private var ordinaryVisualFrames: [[String: Any]] = []
    private var traceOverflow = false
    private var base: TimeInterval = 0
    private var initialKey: NSWindow?
    private var group = ""
    private var role = ""
    private var sourceCommit = ""
    private var plan: [String: Any] = [:]
    private var planHash = ""
    private var planJSON = ""
    private var inputs: [[String: Any]] = []
    private var frames: [[String: Any]] = []
    private var paints: [[String: Any]] = []
    private var settlements: [[String: Any]] = []
    private var modes: [[String: Any]] = []
    private var lastPaintSequence: UInt64 = 0
    private var paintSequenceGaps = 0
    private var lastFrameTime: TimeInterval?
    private var lastFrameGeneration: Int?
    private var maxCallbackGap: TimeInterval = 0
    private var maxApplyDuration: TimeInterval = 0
    private var minScheduledLead = Double.infinity
    private var maxScheduledLead = -Double.infinity
    private var maxInputLateness: TimeInterval = 0
    private var generation = 0
    private var previousTarget: Double?
    private var previousOwner: String?
    private var previousRunning = false
    private var activeTransition: Transition?
    private var lastSettlement: (transition: Transition, time: TimeInterval)?
    private var targetChanges = 0
    private var interruptedTransitions = 0
    private var inside = CGPoint.zero
    private var outside = CGPoint.zero

    init(screen: NSScreen, completion: @escaping (Bool) -> Void) {
        self.screen = screen; self.completion = completion
        super.init()
    }

    func start() {
        guard !started, !finished else { return }
        started = true; initialKey = NSApp.keyWindow
        let timer = Timer(timeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish(false, failure: "independent 45-second deadline exceeded") }
        }
        watchdog = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.run(); self.finish(true) }
            catch {
                let message = (error as? Failure)?.message ?? "synthetic fixture operation failed"
                self.finish(false, failure: message)
            }
        }
    }

    private func run() async throws {
        try require(["--music-test", "--motion-test", "--baseline-motion-test"].allSatisfy {
            CommandLine.arguments.contains($0)
        }, "shared harness requires explicit synthetic Music, motion and comparison flags")
        group = argument("--baseline-motion-group") ?? ""
        role = argument("--baseline-motion-role") ?? ""
        sourceCommit = argument("--baseline-motion-source") ?? "unspecified"
        try require(["ordinary", "steady-music", "playback-edge"].contains(group)
            && ["baseline", "candidate"].contains(role), "comparison group and provenance role are explicit")
        let document = try LRCParser.parse("[00:00]Amber paper birds cross the bay")
        let music = MusicLyricsController(synthetic: true, reader: reader,
            lookup: { _, _ in throw LyricsLookupError.consentRequired }, importer: { _ in document })
        let model = MeterModel(demo: true, music: music)
        self.controller = music; self.model = model
        let geometry = try makeGeometry()
        // Identical global coordinates in both versions, independent of their
        // current shell size or the presence of candidate-only accessory wings.
        inside = CGPoint(x: geometry.notch.midX, y: geometry.notch.minY - 2)
        outside = CGPoint(x: geometry.notch.midX,
            y: geometry.screen.maxY - geometry.notch.height - 8 - geometry.contentHeight - 12)
        try require(geometry.hoverContains(inside, progress: 0)
            && geometry.hoverContains(inside, progress: 1)
            && geometry.screen.contains(outside) && !geometry.hoverContains(outside, progress: 1),
            "fixed raw-notch inputs enter centrally and exit just below the shared full-height shell")
        let panel = IslandPanelController(model: model, geometry: geometry, startPolling: false,
            reducedMotionOverride: false, motionSample: { [weak self] sample in self?.capture(sample) },
            hovered: {}, refresh: {}, settings: {}, quit: {})
        self.panel = panel
        panel.panel.appearance = NSAppearance(named: .aqua)
        music.start()
        try await waitUntil("initial normal panel has a natural settled paint") { self.isSettled(panel) }

        let steps = makeSteps()
        plan = ["schema": 1, "group": group, "inputLevel": "controller-fixed-global-point",
            "screen": rect(screen.frame), "backingScale": Double(screen.backingScaleFactor),
            "rawNotch": rect(geometry.notch), "inside": point(inside), "outside": point(outside),
            "contentHeight": 260, "reduceMotion": false, "motionProfile": "adaptive",
            "track": "Original Synthetic Baseline", "duration": 120, "position": 1,
            "document": "[00:00]Amber paper birds cross the bay", "enabled": group != "ordinary",
            "steps": steps.map { step -> [String: Any] in
                var row: [String: Any] = ["at": step.time, "kind": step.kind, "value": step.value]
                if step.kind == "pointer" { row["point"] = point(step.value == "inside" ? inside : outside) }
                return row
            }]
        let canonical = try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys])
        guard let exactJSON = String(data: canonical, encoding: .utf8) else {
            throw Failure(message: "common input plan is not UTF-8 JSON")
        }
        // Preserve the exact bytes hashed here. Other JSON libraries may emit
        // equivalent Double values with different decimal spellings.
        planJSON = exactJSON
        planHash = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        base = CACurrentMediaTime()
        let observer = Timer(timeInterval: 1.0 / 120, target: self, selector: #selector(observe), userInfo: nil, repeats: true)
        self.observer = observer; RunLoop.main.add(observer, forMode: .common)
        music.setEnabled(group != "ordinary")
        inputs.append(["index": 0, "planned": 0, "delivered": CACurrentMediaTime() - base,
            "kind": "enabled", "value": group != "ordinary"])
        observe()
        for step in steps {
            let remaining = base + step.time - CACurrentMediaTime()
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            try Task.checkCancellation()
            try require(!finished, "comparison remains inside its bounded invocation")
            try await apply(step)
        }
        observe()
        try require(!traceOverflow && !frames.isEmpty && paints.count >= 3,
                    "bounded native callback and distinct paint evidence is present")
        try require(settlements.count == (group == "playback-edge" ? 6 : 4),
                    "all fixed-plan convergence checkpoints were observed")
        try require(NSApp.keyWindow === initialKey && panel.placementIsValid && isSettled(panel),
                    "comparison ends naturally settled with unchanged key focus")
        if group == "ordinary" {
            try require(await reader.callCount() == 0 && !music.enabled,
                        "ordinary group performs no synthetic or real Music read")
        } else {
            try require(music.isPlayingForPresentation && music.hasLocalLyrics,
                        "music group ends with fresh usable synthetic playback")
        }
        timedElapsed = CACurrentMediaTime() - base
        collectingTimedEvidence = false
        self.observer?.invalidate(); self.observer = nil
        if group == "ordinary" { try await captureOrdinaryVisualRound() }
    }

    // Separate visual replay after timing has ended. Rasterization can force a
    // draw, so it must never be part of the timed comparison or natural-paint gate.
    private func captureOrdinaryVisualRound() async throws {
        guard let panel else { throw Failure(message: "ordinary visual panel missing") }
        let directory: URL
        if role == "candidate" {
            directory = URL(fileURLWithPath: "dist/contour-rendering/ordinary-candidate", isDirectory: true)
        } else {
            guard let output = argument("--baseline-motion-output") else {
                throw Failure(message: "baseline visual replay requires its isolated comparison output directory")
            }
            directory = URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent("ordinary-visual", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for opening in [true, false] {
            let began = CACurrentMediaTime()
            var saved = 0
            var lastSequence: UInt64 = 0
            var lastCapturedProgress = opening ? 0.0 : 1.0
            let thresholds = opening ? [0.15, 0.40, 0.70] : [0.80, 0.50, 0.20]
            while CACurrentMediaTime() - began < 2.5 {
                panel.smokePointer(at: opening ? inside : outside, now: ProcessInfo.processInfo.systemUptime)
                if saved < 3, let paint = panel.paintReceipt, paint.observed >= began,
                   paint.sequence > lastSequence, paint.frame.progress == panel.smokeProgress,
                   (opening ? paint.frame.progress > lastCapturedProgress : paint.frame.progress < lastCapturedProgress),
                   paint.frame.progress > 0, paint.frame.progress < 1,
                   (opening ? paint.frame.progress >= thresholds[saved] : paint.frame.progress <= thresholds[saved]) {
                    // Inspect a naturally submitted paint before cacheDisplay.
                    let expected = IslandContour(rect: panel.geometry.contourRect(progress: paint.frame.progress),
                        progress: paint.frame.progress, cornerAdjustment: panel.geometry.shapeCalibration.corner,
                        referenceDepth: panel.geometry.notch.height)
                    try require(paint.frame.contour == expected && paint.actualViewport == paint.frame.viewport,
                                "ordinary visual frame has fresh matching native contour and viewport")
                    guard let view = panel.panel.contentView,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        throw Failure(message: "ordinary own-view bitmap unavailable")
                    }
                    let captureBounds = view.bounds
                    try require(captureBounds.size == paint.actualViewport,
                                "ordinary capture starts at the naturally painted viewport")
                    view.cacheDisplay(in: captureBounds, to: bitmap)
                    guard let afterCapture = panel.paintReceipt else {
                        throw Failure(message: "ordinary own-view capture lost its paint receipt")
                    }
                    try require(panel.smokeProgress == paint.frame.progress && view.bounds == captureBounds
                        && afterCapture.frame.progress == paint.frame.progress
                        && afterCapture.actualViewport == paint.actualViewport
                        && afterCapture.frame.viewport == paint.frame.viewport,
                        "ordinary capture preserves natural progress and viewport through rasterization")
                    // cacheDisplay may submit another receipt synchronously. Consume
                    // it, and also require subsequent progress to advance, so that
                    // forced redraw cannot masquerade as the next natural sample.
                    lastSequence = max(paint.sequence, afterCapture.sequence)
                    lastCapturedProgress = paint.frame.progress
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw Failure(message: "ordinary own-view PNG encoding failed")
                    }
                    saved += 1
                    let direction = opening ? "open" : "close"
                    let file = directory.appendingPathComponent("perimeter-ordinary-\(direction)-\(saved).png")
                    try png.write(to: file, options: .atomic)
                    ordinaryVisualFrames.append(["direction": direction, "sample": saved, "file": file.path,
                        "progress": paint.frame.progress, "paintSequence": paint.sequence,
                        "postCaptureSequence": lastSequence, "captureProgress": afterCapture.frame.progress,
                        "naturalViewport": size(paint.actualViewport), "captureViewport": size(afterCapture.actualViewport),
                        "paintObserved": paint.observed, "nativeWidth": Double(panel.panel.frame.width),
                        "contourWidth": Double(paint.frame.contour.rect.width), "timedEvidence": false, "scanout": false])
                }
                if saved == 3 && isSettled(panel) && panel.smokeTargetProgress == (opening ? 1 : 0) { break }
                try await Task.sleep(nanoseconds: 8_000_000)
            }
            try require(saved == 3 && isSettled(panel) && panel.smokeTargetProgress == (opening ? 1 : 0),
                        "ordinary separate visual replay retains three distinct in-flight images and settles")
        }
    }

    private func makeSteps() -> [Step] {
        var result: [Step] = []
        func add(_ time: Double, _ kind: String, _ value: String) { result.append(Step(time: time, kind: kind, value: value)) }
        if group == "playback-edge" {
            add(0.10, "read", "playing"); add(0.16, "import", "local")
            add(0.95, "checkpoint", "pre-hover")
            add(1.30, "read", "paused"); add(2.25, "checkpoint", "paused")
            // A real pending paused read arrives after the unchanged 3 s poll.
            add(4.50, "read", "playing"); add(5.35, "checkpoint", "reconnected")
            add(5.50, "pointer", "inside"); add(5.66, "pointer", "inside")
            add(5.75, "read", "playing"); add(6.50, "checkpoint", "details-open")
            add(7.00, "read", "playing")
            add(7.05, "pointer", "outside"); add(7.29, "pointer", "outside")
            add(7.36, "pointer", "inside"); add(7.52, "pointer", "inside")
            add(8.25, "read", "playing"); add(8.50, "checkpoint", "details-reopened")
            add(8.70, "pointer", "outside"); add(8.94, "pointer", "outside")
            add(9.10, "pointer", "outside"); add(9.26, "pointer", "outside"); add(9.42, "pointer", "outside")
            add(9.50, "read", "playing"); add(10.35, "checkpoint", "final")
        } else {
            if group == "steady-music" {
                for time in [0.10, 1.30, 2.50, 3.70, 4.90] { add(time, "read", "playing") }
                add(0.16, "import", "local")
            }
            add(0.95, "checkpoint", "pre-hover")
            add(1.05, "pointer", "inside"); add(1.21, "pointer", "inside")
            add(2.05, "checkpoint", "details-open")
            add(2.65, "pointer", "outside"); add(2.89, "pointer", "outside")
            add(2.96, "pointer", "inside"); add(3.12, "pointer", "inside")
            add(4.10, "checkpoint", "details-reopened")
            add(4.30, "pointer", "outside"); add(4.54, "pointer", "outside")
            add(4.70, "pointer", "outside"); add(4.86, "pointer", "outside"); add(5.02, "pointer", "outside")
            add(5.95, "checkpoint", "final")
        }
        return result.sorted { $0.time < $1.time }
    }

    private func apply(_ step: Step) async throws {
        guard let panel, let controller else { throw Failure(message: "missing synthetic panel") }
        let delivered = CACurrentMediaTime() - base
        maxInputLateness = max(maxInputLateness, delivered - step.time)
        var row: [String: Any] = ["index": inputs.count, "planned": step.time,
            "delivered": delivered, "kind": step.kind, "value": step.value]
        if step.kind == "pointer" {
            let location = step.value == "inside" ? inside : outside
            let timestamp = ProcessInfo.processInfo.systemUptime
            row["point"] = point(location); row["timestamp"] = timestamp
            inputs.append(row)
            panel.smokePointer(at: location, now: timestamp)
        } else {
            inputs.append(row)
            switch step.kind {
            case "read":
                let state: MusicPlaybackState = step.value == "paused" ? .paused : .playing
                guard let identity = MusicTrackIdentity(title: "Original Synthetic Baseline", artist: "Fixture Ensemble",
                    album: "Native Comparison", duration: 120),
                      let snapshot = MusicPlaybackSnapshot(track: identity, state: state, position: 1,
                        observedAt: ProcessInfo.processInfo.systemUptime) else { throw Failure(message: "invalid original fixture") }
                try require(await reader.release(.snapshot(snapshot)), "scheduled playback input completes an actual pending read")
                try await waitUntil("scheduled snapshot reaches the real Music controller", timeout: 0.5) {
                    controller.syntheticPlaybackSnapshot == snapshot
                }
            case "import":
                guard let token = controller.importSelectionToken else { throw Failure(message: "fresh fixture cannot import original lyrics") }
                controller.importLyrics(from: URL(fileURLWithPath: "/synthetic-baseline-comparison.lrc"), for: token)
                try await waitUntil("in-memory importer reaches the production controller", timeout: 0.5) {
                    controller.hasLocalLyrics && controller.line == "Amber paper birds cross the bay"
                }
            case "checkpoint": try checkpoint(step.value)
            default: throw Failure(message: "unknown fixed-plan input")
            }
        }
        observe()
    }

    private func capture(_ sample: IslandMotionSample) {
        guard base > 0, !finished, collectingTimedEvidence, let panel else { return }
        guard frames.count < 6000 else { traceOverflow = true; return }
        generation = sample.generation
        // Intentional idle intervals between retired frame sources are not frame
        // stalls. Compare callback gaps only within one production generation.
        if lastFrameGeneration == sample.generation, let previous = lastFrameTime {
            maxCallbackGap = max(maxCallbackGap, sample.observed - previous)
        }
        lastFrameTime = sample.observed; lastFrameGeneration = sample.generation
        maxApplyDuration = max(maxApplyDuration, sample.applyDuration)
        minScheduledLead = min(minScheduledLead, sample.scheduled - sample.observed)
        maxScheduledLead = max(maxScheduledLead, sample.scheduled - sample.observed)
        frames.append(["sequence": frames.count + 1, "t": sample.observed - base,
            "scheduled": sample.scheduled - base, "generation": sample.generation, "source": sample.source,
            "progress": sample.progress, "velocity": sample.velocity, "target": panel.smokeTargetProgress,
            "owner": String(describing: panel.smokeExpansionOwner), "frame": rect(sample.frame),
            "contentBounds": rect(sample.contentBounds), "viewport": size(sample.viewport),
            "renderedProgress": panel.motionProbe.renderedProgress, "applyDuration": sample.applyDuration])
        observe()
    }

    @objc private func observe() {
        guard base > 0, !finished, collectingTimedEvidence, let panel else { return }
        let now = CACurrentMediaTime() - base
        if let paint = panel.paintReceipt, paint.sequence != lastPaintSequence {
            if paints.count >= 6000 { traceOverflow = true; return }
            if lastPaintSequence > 0 && paint.sequence > lastPaintSequence + 1 {
                paintSequenceGaps += Int(paint.sequence - lastPaintSequence - 1)
            }
            lastPaintSequence = paint.sequence
            // Pre-plan initial paint is excluded rather than relabeled as a new
            // paint. v1.0.0 exposes latest(), not a complete Canvas history.
            if paint.observed >= base {
                paints.append(["sequence": paint.sequence, "t": paint.observed - base, "collectedAt": CACurrentMediaTime() - base,
                    "progress": paint.frame.progress, "viewport": size(paint.frame.viewport),
                    "actualViewport": size(paint.actualViewport), "contour": rect(paint.frame.contour.rect),
                    "bodyBounds": rect(paint.bodyBounds), "railBounds": rect(paint.railBounds)])
            }
        }
        let target = panel.smokeTargetProgress, owner = String(describing: panel.smokeExpansionOwner)
        let running = panel.smokeMotionRunning
        if previousTarget != target || previousOwner != owner || (running && !previousRunning) {
            if activeTransition != nil { interruptedTransitions += 1 }
            if previousTarget != nil { targetChanges += 1 }
            let event = panel.smokeRetarget?.eventTime ?? CACurrentMediaTime()
            let began = min(now, max(0, event - base))
            activeTransition = Transition(started: began, target: target, owner: owner, inputIndex: max(0, inputs.count - 1))
            previousTarget = target; previousOwner = owner
        }
        previousRunning = running
        if let transition = activeTransition, isSettled(panel) {
            lastSettlement = (transition, now); activeTransition = nil
        }
    }

    private func checkpoint(_ name: String) throws {
        guard let panel, let controller else { throw Failure(message: "checkpoint has no panel") }
        observe()
        try require(isSettled(panel), "fixed-plan checkpoint \(name) has naturally settled native geometry and paint")
        let owner = String(describing: panel.smokeExpansionOwner), target = panel.smokeTargetProgress
        if name == "details-open" || name == "details-reopened" {
            try require(target == 1 && panel.smokeExpansionOwner == .details,
                        "shared fixed-point hover reaches ordinary details")
        } else if group == "ordinary" || name == "paused" {
            try require(target == 0 && panel.smokeExpansionOwner == .idle,
                        "ordinary or paused endpoint is the genuine idle state")
        }
        let settled = lastSettlement
        if name == "final" {
            // Planned spacing is not proof of dwell: delayed dispatch can compress
            // samples. Require the final uninterrupted, actually delivered exit.
            let lastInside = inputs.lastIndex { ($0["kind"] as? String) == "pointer" && ($0["value"] as? String) == "inside" } ?? -1
            let exits = inputs.enumerated().filter { $0.offset > lastInside && ($0.element["kind"] as? String) == "pointer" && ($0.element["value"] as? String) == "outside" }
            guard let first = exits.first, let last = exits.last,
                  let firstTime = first.element["timestamp"] as? Double, let lastTime = last.element["timestamp"] as? Double,
                  let delivered = first.element["delivered"] as? Double,
                  let settled, let initial = modes.first(where: { ($0["name"] as? String) == "pre-hover" }),
                  let initialFrame = initial["frame"] as? [Double], let paint = panel.paintReceipt else {
                throw Failure(message: "final exit lacks fresh transition and initial geometry evidence")
            }
            try require(exits.count >= 3 && lastTime - firstTime >= 0.22,
                        "final outside samples actually span the hover exit threshold")
            try require(settled.transition.inputIndex >= first.offset && settled.transition.started >= delivered
                && settled.time >= settled.transition.started && paint.observed - base >= settled.transition.started,
                        "final settlement and natural paint belong to this final outside transition")
            try require(owner == (initial["owner"] as? String) && target == (initial["target"] as? Double)
                && abs(Double(panel.panel.frame.width) - initialFrame[2]) <= 0.001,
                        "final exit restores its own pre-hover owner and closed width")
        }
        let began = settled?.transition.started ?? 0, at = settled?.time ?? (CACurrentMediaTime() - base)
        settlements.append(["name": name, "inputIndex": settled?.transition.inputIndex ?? 0,
            "target": target, "targetStarted": began, "t": at, "latency": max(0, at - began),
            "frame": rect(panel.panel.frame), "owner": owner, "progress": panel.smokeProgress,
            "generation": generation, "checkpointObservedAt": CACurrentMediaTime() - base,
            "paintObservedAt": (panel.paintReceipt?.observed ?? base) - base])
        modes.append(["name": name, "t": CACurrentMediaTime() - base, "progress": panel.smokeProgress,
            "target": target, "frame": rect(panel.panel.frame), "owner": owner,
            "playing": controller.isPlayingForPresentation])
    }

    private func isSettled(_ panel: IslandPanelController) -> Bool {
        let probe = panel.motionProbe, target = panel.smokeTargetProgress
        let expected = panel.geometry.frame(progress: target)
        guard let paint = panel.paintReceipt else { return false }
        let contour = IslandContour(rect: panel.geometry.contourRect(progress: target), progress: target,
            cornerAdjustment: panel.geometry.shapeCalibration.corner, referenceDepth: panel.geometry.notch.height)
        return !panel.smokeMotionRunning && !panel.closePresentationPending && panel.smokeVelocity == 0
            && panel.smokeProgress == target && probe.requestedProgress == target && probe.renderedProgress == target
            && probe.frame == expected && probe.contentBounds == CGRect(origin: .zero, size: expected.size)
            && probe.viewport == expected.size && probe.visible && probe.nonKey && panel.placementIsValid
            && paint.frame.progress == target && paint.frame.contour == contour
            && paint.frame.viewport == expected.size && paint.actualViewport == expected.size
            && NSApp.keyWindow === initialKey
    }

    private func makeGeometry() throws -> IslandGeometry {
        let frame = screen.frame, inset: CGFloat = 32, width: CGFloat = 220
        let left = frame.midX - width / 2, right = frame.midX + width / 2
        guard let notch = NotchGeometry.calculate(screen: frame, topInset: Double(inset),
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - inset, width: left - frame.minX, height: inset),
            auxiliaryRight: CGRect(x: right, y: frame.maxY - inset, width: frame.maxX - right, height: inset)) else {
            throw Failure(message: "synthetic common notch geometry unavailable")
        }
        return IslandGeometry(notch: notch, screen: frame, backingScale: screen.backingScaleFactor, contentHeight: 260)
    }
    private func waitUntil(_ message: String, timeout: TimeInterval = 3.6,
        condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !finished && !Task.isCancelled && CACurrentMediaTime() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure(message: message)
    }
    private func require(_ valid: Bool, _ message: String) throws {
        if !valid { throw Failure(message: message) }
    }
    private func argument(_ key: String) -> String? {
        let prefix = key + "="
        return CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }
    private func point(_ value: CGPoint) -> [Double] { [Double(value.x), Double(value.y)] }
    private func size(_ value: CGSize) -> [Double] { [Double(value.width), Double(value.height)] }
    private func rect(_ value: CGRect) -> [Double] { [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)] }

    private func finish(_ success: Bool, failure: String = "") {
        guard !finished else { return }
        observe()
        finished = true
        let elapsed = timedElapsed ?? (base > 0 ? CACurrentMediaTime() - base : 0)
        let valid = success && elapsed < 45 && !traceOverflow
        let payload: [String: Any] = ["schema": 1, "success": valid, "failure": failure,
            "role": role, "group": group, "sourceCommit": sourceCommit,
            "synthetic": true, "controllerLevelInput": true, "nativeIngress": false, "scanout": false,
            "baselineHasMusicWings": false,
            "modeComparison": "shared input responses; v1.0.0 automatic compact versus candidate default closed; no invented baseline wings",
            "inputPlan": plan, "inputPlanJSON": planJSON, "inputPlanSHA256": planHash, "inputs": inputs, "frames": frames,
            "paints": paints, "paintCollection": "latest-receipt-observer", "paintSequenceGaps": paintSequenceGaps,
            "stateObserverInterval": 1.0 / 120, "settlements": settlements, "modeSamples": modes,
            "metrics": ["frameCount": frames.count, "paintCount": paints.count, "maxCallbackGap": maxCallbackGap,
                "maxApplyDuration": maxApplyDuration, "minScheduledLead": minScheduledLead.isFinite ? minScheduledLead : 0,
                "maxScheduledLead": maxScheduledLead.isFinite ? maxScheduledLead : 0, "targetChanges": targetChanges,
                "interruptedTransitions": interruptedTransitions, "maxInputLateness": maxInputLateness],
            "historyOverflow": traceOverflow, "elapsed": elapsed,
            "ordinaryVisualFrames": ordinaryVisualFrames, "visualReplayExcludedFromTiming": true]
        stop()
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try require(data.count < 2_000_000, "bounded comparison trace exceeds two megabytes")
            guard let line = String(data: data, encoding: .utf8) else { throw Failure(message: "trace encoding failed") }
            print("BASELINE_MOTION_JSON: \(line)")
            if let output = argument("--baseline-motion-output") {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("baseline-motion-\(role)-\(group).json"), options: .atomic)
            }
            print(valid
                ? "BASELINE_MOTION_OK: group=\(group) role=\(role) inputPlanSHA256=\(planHash) controllerLevel=true nativeIngress=false scanout=false"
                : "BASELINE_MOTION_FAILED: group=\(group) role=\(role) reason=\(failure)")
            completion(valid)
        } catch {
            print("BASELINE_MOTION_FAILED: cannot encode or preserve bounded synthetic trace")
            completion(false)
        }
    }

    func stop() {
        observer?.invalidate(); observer = nil
        watchdog?.invalidate(); watchdog = nil
        task?.cancel(); task = nil
        panel?.stop(); controller?.stop()
        Task { await reader.stop() }
    }
}

/// Holds actual production read requests until the common plan releases the
/// same original snapshot. No Music IPC, selected file or network is involved.
private actor BaselineComparisonReader: MusicSnapshotProvider {
    private var pending: CheckedContinuation<MusicReadResult, Never>?
    private var reads = 0
    private var stopped = false
    func read(allowPermissionPrompt: Bool) async -> MusicReadResult {
        guard !stopped, pending == nil else { return .unavailable(.cancelled) }
        reads += 1
        return await withCheckedContinuation { pending = $0 }
    }
    func release(_ result: MusicReadResult) -> Bool {
        guard let continuation = pending else { return false }
        pending = nil; continuation.resume(returning: result); return true
    }
    func callCount() -> Int { reads }
    func stop() {
        stopped = true
        pending?.resume(returning: .unavailable(.cancelled)); pending = nil
    }
}
#endif
