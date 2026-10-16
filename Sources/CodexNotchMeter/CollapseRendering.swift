#if os(macOS)
import AppKit
import QuartzCore
import NotchCore

/// Own-window observations and separately replayed bitmap samples. Neither is scanout.
@MainActor
final class CollapseRenderHarness: NSObject {
    private let model: MeterModel
    private let geometry: IslandGeometry
    private let completion: (Bool) -> Void
    private var controller: IslandPanelController?
    private var timer: Timer?
    private var phase = 0
    private var phaseStarted = CACurrentMediaTime()
    private var cycle = 0
    private var passed = true
    private var tailSamples = 0
    private var settledProbes = 0
    private var zeroRequestedAt: TimeInterval?
    private var firstClosedPixels: [Int: [Double]] = [:]
    private var rowOrientation: [Int: Bool] = [:]
    private var replayTheme = 0
    private var replayIndex = 0
    private var replayPixels: [Int: [[Double]]] = [:]
    private var intercepted = false
    private var captureCount = 0
    private let progressPoints: [Double] = [0.50, 0.30, 0.10, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001, 0.0005, 0]
    private var themes: [MeterTheme] { MeterTheme.allCases }
    private var isBaseline: Bool { cycle == 0 }
    private var isFallback: Bool { cycle == themes.count + 1 }
    private var isInterruption: Bool { cycle >= themes.count + 2 }
    private var label: String {
        if isBaseline { return "old-immediate-retirement/shared-current-paint" }
        if isFallback { return "dispatch-fallback" }
        if isInterruption { return cycle == themes.count + 2 ? "pending-reentry" : "pending-stop" }
        return "drained-\(themes[cycle - 1].rawValue)"
    }
    init(model: MeterModel, geometry: IslandGeometry, completion: @escaping (Bool) -> Void) {
        self.model = model; self.geometry = geometry; self.completion = completion
        super.init()
    }
    func start() {
        guard model.demo, CommandLine.arguments.contains("--collapse-test"), calibrate() else { finish(false); return }
        startCycle()
        let timer = Timer(timeInterval: 0.01, target: self, selector: #selector(check(_:)), userInfo: nil, repeats: true)
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func calibrate() -> Bool {
        for scale in [1, 2] {
            let view = ScaleCalibrationView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
            guard let raw = NativeContourBitmap.capture(view, scale: scale, topRowFirst: true) else { return false }
            let first = raw.pixel(x: 2 * scale, y: scale), last = raw.pixel(x: 2 * scale, y: 6 * scale)
            let topFirst = first.r > 0.8 && last.b > 0.8
            let bottomFirst = first.b > 0.8 && last.r > 0.8
            let valid = (topFirst || bottomFirst) && raw.representation.pixelsWide == 8 * scale
                && raw.representation.pixelsHigh == 8 * scale
                && abs(view.drawingScale.width - CGFloat(scale)) < 0.001
                && abs(view.drawingScale.height - CGFloat(scale)) < 0.001
            SmokeDiagnostics.mark("collapse calibration scale=\(scale) CTM=\(view.drawingScale) dimensions=\(raw.representation.pixelsWide)x\(raw.representation.pixelsHigh) valid=\(valid)")
            guard valid else { return false }
            rowOrientation[scale] = topFirst
        }
        return true
    }
    private func startCycle() {
        controller?.stop(); tailSamples = 0; settledProbes = 0; zeroRequestedAt = nil
        firstClosedPixels = [:]; intercepted = false
        model.theme = cycle > 0 && cycle <= themes.count ? themes[cycle - 1] : .standard
        model.setContourFixture(left: 83, right: 38)
        controller = IslandPanelController(model: model, geometry: geometry, startPolling: false,
            reducedMotionOverride: false, motionProfile: isFallback ? .timerFallback : .adaptive,
            drainsClosePresentation: !isBaseline, motionSample: { [weak self] in self?.observe($0) },
            hovered: {}, refresh: {}, settings: {}, quit: {})
        phase = 0; phaseStarted = CACurrentMediaTime()
        SmokeDiagnostics.mark("collapse cycle=\(label) actualBacking=\(controller?.panel.backingScaleFactor ?? 0) pointGeometry=\(geometry.frame(progress: 0))")
    }
    private func observe(_ sample: IslandMotionSample) {
        guard !sample.expanded, sample.progress <= 0.1, let island = controller else { return }
        tailSamples += 1
        let probe = island.motionProbe
        if sample.progress == 0, zeroRequestedAt == nil { zeroRequestedAt = sample.observed }
        SmokeDiagnostics.mark("collapse applied cycle=\(label) observed=\(sample.observed) scheduled=\(sample.scheduled) requested=\(sample.progress) rendered=\(probe.renderedProgress) renderedAt=\(probe.renderedAt) frame=\(sample.frame) viewport=\(probe.viewport) layer=\(String(describing: probe.layerPresentation)) sourceRunning=\(probe.running) pending=\(island.closePresentationPending)")
        // Exercise reentry/teardown in the real requesting callback, before its source
        // can acknowledge the next run-loop view update. No bitmap/layout work here.
        if isInterruption, sample.progress == 0, island.closePresentationPending, !intercepted {
            intercepted = true
            if cycle == themes.count + 2 {
                island.beginSmokeExpansion()
                let valid = !island.closePresentationPending && island.smokeTargetExpanded && island.smokeMotionRunning
                passed = valid && passed
                SmokeDiagnostics.mark("collapse pending reentry cancelled immediately valid=\(valid)")
                phase = 8; phaseStarted = CACurrentMediaTime()
            } else {
                let valid = island.verifyRetiredCloseIsInert()
                passed = valid && passed
                SmokeDiagnostics.mark("collapse pending deadline/frame retirement inert=\(valid)")
                phase = 9; phaseStarted = CACurrentMediaTime()
            }
        }
    }
    private func next(_ phase: Int, at now: TimeInterval) { self.phase = phase; phaseStarted = now }
    @objc private func check(_ sender: Timer) {
        guard sender === timer, let island = controller else { return }
        let now = CACurrentMediaTime(), elapsed = now - phaseStarted
        guard elapsed < 3 else {
            SmokeDiagnostics.mark("collapse deadline cycle=\(label) phase=\(phase) progress=\(island.smokeProgress)")
            finish(false); return
        }
        switch phase {
        case 0 where elapsed >= 0.15:
            island.beginSmokeExpansion(); next(1, at: now)
        case 1 where island.smokeProgress == 1 && !island.smokeMotionRunning:
            next(2, at: now)
        case 2 where elapsed >= 0.08:
            passed = island.verifyExpandedLayout(includePixels: false) && passed
            island.collapse(); next(3, at: now)
        case 3:
            if island.smokeProgress <= 0.02 { logNormalProbe(island) }
            if island.smokeProgress == 0 && !island.smokeMotionRunning {
                guard !isInterruption else { finish(false); return }
                let receipt = island.closeReceipt
                let ready = receipt.map { event in
                    event.outcome == .ready && (event.paintedAt ?? 0) >= event.requestedAt
                        && (event.renderedAt ?? 0) >= event.requestedAt
                        && (event.acknowledgedAt ?? .infinity) > event.requestedAt
                        && (event.acknowledgedAt ?? .infinity) - event.requestedAt < 0.12
                        && (event.renderedAt ?? 0) >= event.requestedAt
                        && (event.completedAt ?? 0) >= (event.acknowledgedAt ?? .infinity)
                        && event.finalDisplayDuration.isFinite && event.finalDisplayDuration >= 0
                } ?? false
                let valid = tailSamples >= 4 && (isBaseline || ready)
                passed = (isBaseline || valid) && passed
                SmokeDiagnostics.mark("collapse retirement cycle=\(label) tailCallbacks=\(tailSamples) requestedAt=\(String(describing: receipt?.requestedAt)) acknowledgedAt=\(String(describing: receipt?.acknowledgedAt)) retiredAt=\(String(describing: receipt?.completedAt)) finalDisplaySeconds=\(String(describing: receipt?.finalDisplayDuration)) viewUpdatedAt=\(String(describing: receipt?.renderedAt)) paintedAt=\(String(describing: receipt?.paintedAt)) outcome=\(String(describing: receipt?.outcome)) valid=\(valid)")
                next(4, at: now)
            }
        case 4:
            // Non-forcing probes occur before any bitmap capture can flush drawing.
            let probe = island.motionProbe
            let matches = probe.requestedProgress == 0 && probe.renderedProgress == 0
                && probe.renderedAt >= (zeroRequestedAt ?? .infinity)
                && probe.viewport == geometry.frame(progress: 0).size
                && probe.frame == geometry.frame(progress: 0)
                && probe.contentBounds == CGRect(origin: .zero, size: probe.frame.size)
                && probe.layerPresentation == CGRect(origin: .zero, size: probe.frame.size)
                && probe.visible && probe.nonKey && !probe.running
            logNormalProbe(island)
            if matches { settledProbes += 1 }
            else if elapsed > 0.12, !isBaseline { passed = false }
            if settledProbes >= 2 {
                firstClosedPixels = captureBoth(island)
                passed = firstClosedPixels.count == 2 && passed
                next(5, at: now)
            } else if elapsed > 0.2 {
                SmokeDiagnostics.mark("collapse settled observation cycle=\(label) freshMatchingProbes=\(settledProbes) within200ms=false baselineObservational=\(isBaseline)")
                if isBaseline { advanceCycle() } else { finish(false) }
                return
            }
        case 5 where elapsed >= 0.12:
            let stable = captureBoth(island)
            for scale in [1, 2] {
                guard let initial = firstClosedPixels[scale], let final = stable[scale] else { finish(false); return }
                let delta = normalizedDifference(initial, final, reference: final)
                let valid = delta <= 0.005
                passed = (isBaseline || valid) && passed
                SmokeDiagnostics.mark("collapse settled own-view replay cycle=\(label) scale=\(scale) firstVsLaterDelta=\(delta) valid=\(valid) scanout=false")
            }
            advanceCycle()
        case 8 where island.smokeProgress == 1 && !island.smokeMotionRunning:
            passed = intercepted && !island.closePresentationPending && passed
            advanceCycle()
        case 9 where elapsed >= 0.15:
            passed = intercepted && island.smokeStopped && !island.closePresentationPending && passed
            advanceCycle()
        case 20 where elapsed >= 0.07:
            let captured = captureBoth(island)
            for scale in [1, 2] {
                guard let pixels = captured[scale] else { finish(false); return }
                replayPixels[scale, default: []].append(pixels)
            }
            replayIndex += 1
            if replayIndex < progressPoints.count {
                island.setContourTestProgress(progressPoints[replayIndex]); next(20, at: CACurrentMediaTime())
            } else {
                inspectReplay()
                replayTheme += 1
                if replayTheme < themes.count { startReplay() }
                else { finish(passed) }
            }
        default: break
        }
    }
    private func logNormalProbe(_ island: IslandPanelController) {
        let probe = island.motionProbe
        SmokeDiagnostics.mark("collapse normal-runloop cycle=\(label) time=\(probe.observed) requested=\(probe.requestedProgress) rendered=\(probe.renderedProgress) renderedAt=\(probe.renderedAt) frame=\(probe.frame) viewport=\(probe.viewport) presentation=\(String(describing: probe.layerPresentation)) running=\(probe.running)")
    }
    private func advanceCycle() {
        cycle += 1
        if cycle < themes.count + 4 { startCycle() }
        else { startReplay() }
    }
    private func startReplay() {
        controller?.stop(); replayIndex = 0; replayPixels = [:]
        model.theme = themes[replayTheme]; model.setContourFixture(left: 83, right: 38)
        controller = IslandPanelController(model: model, geometry: geometry, startPolling: false,
            reducedMotionOverride: false, hovered: {}, refresh: {}, settings: {}, quit: {})
        controller?.setContourTestProgress(progressPoints[0]); next(20, at: CACurrentMediaTime())
    }
    private var canvas: CGRect {
        let frame = geometry.frame(progress: 0.5)
        return CGRect(x: floor(frame.minX) - 2, y: floor(frame.minY) - 2,
            width: ceil(frame.maxX) - floor(frame.minX) + 4,
            height: ceil(frame.maxY) - floor(frame.minY) + 4)
    }
    private func captureBoth(_ island: IslandPanelController) -> [Int: [Double]] {
        guard let view = island.panel.contentView else { return [:] }
        var result: [Int: [Double]] = [:]
        for scale in [1, 2] {
            guard let topFirst = rowOrientation[scale],
                  let bitmap = NativeContourBitmap.capture(view, scale: scale, topRowFirst: topFirst, padToWholePixels: true) else { continue }
            if phase == 20 && replayIndex < 2 {
                passed = IslandPaintParity.check(current: bitmap, model: model, geometry: geometry,
                    progress: progressPoints[replayIndex]) && passed
            }
            let expectedWidth = Int(ceil(view.bounds.width * CGFloat(scale)))
            let expectedHeight = Int(ceil(view.bounds.height * CGFloat(scale)))
            guard bitmap.representation.pixelsWide == expectedWidth, bitmap.representation.pixelsHigh == expectedHeight else { continue }
            let frame = island.panel.frame, area = canvas
            let width = Int(area.width * CGFloat(scale)), height = Int(area.height * CGFloat(scale))
            // Sample in one global point-space canvas, preserving the camera/top anchor.
            // Pixel centers include +0.5; moving native viewport origins are not ignored.
            var values = [Double](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                let globalY = area.maxY - (CGFloat(y) + 0.5) / CGFloat(scale)
                for x in 0..<width {
                    let globalX = area.minX + (CGFloat(x) + 0.5) / CGFloat(scale)
                    let xx = Int(floor((globalX - frame.minX) * CGFloat(scale)))
                    let yy = Int(floor((frame.maxY - globalY) * CGFloat(scale)))
                    guard xx >= 0, yy >= 0, xx < bitmap.representation.pixelsWide, yy < bitmap.representation.pixelsHigh else { continue }
                    let pixel = bitmap.pixel(x: xx, y: yy), offset = (y * width + x) * 4
                    values[offset] = pixel.r * pixel.a; values[offset + 1] = pixel.g * pixel.a
                    values[offset + 2] = pixel.b * pixel.a; values[offset + 3] = pixel.a
                }
            }
            captureCount += 1; result[scale] = values
        }
        return result
    }
    private func normalizedDifference(_ first: [Double], _ second: [Double], reference: [Double]) -> Double {
        guard first.count == second.count, second.count == reference.count else { return .infinity }
        let energy = reference.reduce(0) { $0 + abs($1) }
        guard energy > 1 else { return .infinity }
        return zip(first, second).reduce(0) { $0 + abs($1.0 - $1.1) } / energy
    }
    private func outsideHardware(_ pixels: [Double], scale: Int) -> [Double] {
        let area = canvas
        let width = Int(area.width * CGFloat(scale)), height = Int(area.height * CGFloat(scale))
        guard (scale == 1 || scale == 2), pixels.count == width * height * 4 else { return [] }
        var result = pixels
        for y in 0..<height { for x in 0..<width {
            let point = CGPoint(x: area.minX + (CGFloat(x) + 0.5) / CGFloat(scale),
                y: area.maxY - (CGFloat(y) + 0.5) / CGFloat(scale))
            if geometry.notch.contains(point) {
                let offset = (y * width + x) * 4
                for channel in 0..<4 { result[offset + channel] = 0 }
            }
        } }
        return result
    }
    private func paintedBounds(_ pixels: [Double], scale: Int) -> CGRect? {
        let area = canvas, width = Int(area.width * CGFloat(scale)), height = Int(area.height * CGFloat(scale))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height { for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0.01 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: area.minX + CGFloat(minX) / CGFloat(scale),
            y: area.maxY - CGFloat(maxY + 1) / CGFloat(scale),
            width: CGFloat(maxX - minX + 1) / CGFloat(scale), height: CGFloat(maxY - minY + 1) / CGFloat(scale))
    }
    /// Measure each straight-side axis separately, so the long horizontal rail
    /// cannot dilute a one-point viewport displacement in a whole-image average.
    private func sideAxis(_ pixels: [Double], scale: Int, near axis: CGFloat) -> Double? {
        let area = canvas, width = Int(area.width * CGFloat(scale)), height = Int(area.height * CGFloat(scale))
        guard pixels.count == width * height * 4 else { return nil }
        var weightedX = 0.0, weight = 0.0
        for y in 0..<height {
            let depth = geometry.screen.maxY - (area.maxY - (CGFloat(y) + 0.5) / CGFloat(scale))
            guard depth >= 8, depth <= 18 else { continue }
            for x in 0..<width {
                let gx = area.minX + (CGFloat(x) + 0.5) / CGFloat(scale)
                guard abs(gx - axis) <= 4 else { continue }
                let alpha = pixels[(y * width + x) * 4 + 3]
                weightedX += Double(gx) * alpha; weight += alpha
            }
        }
        return weight > 1 ? weightedX / weight : nil
    }
    /// Independent point-space side probes bind visible body and color to the same
    /// progress. The text lies farther inward; the right used tail is intentionally black.
    private func pairedSide(_ pixels: [Double], scale: Int, progress: Double) -> (body: Double, rail: Double)? {
        let native = geometry.frame(progress: progress), rect = geometry.contourRect(progress: progress)
        let side = native.minX + rect.minX + CGFloat(12 * progress)
        let depth = rect.height / 2
        let width = Int(canvas.width * CGFloat(scale)), height = Int(canvas.height * CGFloat(scale))
        guard pixels.count == width * height * 4 else { return nil }
        var bodyEdges: [Double] = [], colorWeight = 0.0, colorX = 0.0
        for y in 0..<height {
            let globalY = canvas.maxY - (CGFloat(y) + 0.5) / CGFloat(scale)
            guard abs(native.maxY - globalY - depth) <= 3 else { continue }
            var first: Double?
            for x in 0..<width {
                let gx = canvas.minX + (CGFloat(x) + 0.5) / CGFloat(scale)
                guard gx >= side - 3, gx <= side + 6 else { continue }
                let index = (y * width + x) * 4
                if first == nil, pixels[index + 3] > IslandReveal.surface(progress) * 0.5 { first = Double(gx) }
                let chroma = max(pixels[index], max(pixels[index + 1], pixels[index + 2]))
                    - min(pixels[index], min(pixels[index + 1], pixels[index + 2]))
                colorWeight += chroma; colorX += Double(gx) * chroma
            }
            if let first { bodyEdges.append(first) }
        }
        guard !bodyEdges.isEmpty, colorWeight > 0.1 else { return nil }
        return (bodyEdges.reduce(0, +) / Double(bodyEdges.count) - Double(side),
            colorX / colorWeight - Double(side + 2))
    }
    private func coherentSide(_ measurement: (body: Double, rail: Double)?, scale: Int) -> Bool {
        guard let measurement else { return false }
        return abs(measurement.body) <= 1 / Double(scale)
            && abs(measurement.rail) <= 0.6 / Double(scale)
    }
    private func inspectReplay() {
        for scale in [1, 2] {
            guard let scenes = replayPixels[scale], scenes.count == progressPoints.count, let idle = scenes.last else { passed = false; continue }
            let visibleIdle = outsideHardware(idle, scale: scale)
            var residuals: [Double] = []
            var visibleResiduals: [Double] = []
            var boxes: [CGRect?] = []
            for index in scenes.indices {
                let visible = outsideHardware(scenes[index], scale: scale)
                let residual = normalizedDifference(scenes[index], idle, reference: idle)
                let visibleResidual = normalizedDifference(visible, visibleIdle, reference: visibleIdle)
                let box = paintedBounds(visible, scale: scale)
                residuals.append(residual); visibleResiduals.append(visibleResidual); boxes.append(box)
                SmokeDiagnostics.mark("collapse tail own-view replay theme=\(themes[replayTheme].rawValue) scale=\(scale) progress=\(progressPoints[index]) fullCanvasDifference=\(residual) outsideExclusionDifference=\(visibleResidual) outsidePaintBounds=\(String(describing: box)) scanout=false")
            }
            // The tiny terminal spring threshold must not turn into a line-sized jump.
            // Exclude the simulated camera rectangle from the visible-change oracle;
            // alpha inside it is separately checked by the opaque-interior control.
            let last = boxes.count - 1
            let terminalBounds = zip(boxes[(last - 2)..<last], [boxes[last], boxes[last]]).allSatisfy { pair in
                guard let first = pair.0, let second = pair.1 else { return false }
                return abs(first.minX - second.minX) <= 1 / CGFloat(scale)
                    && abs(first.maxX - second.maxX) <= 1 / CGFloat(scale)
                    && abs(first.minY - second.minY) <= 1 / CGFloat(scale)
                    && abs(first.maxY - second.maxY) <= 1 / CGFloat(scale)
            }
            let monotonicTail = (3..<visibleResiduals.count).allSatisfy {
                visibleResiduals[$0] <= visibleResiduals[$0 - 1] + 0.015
            }
            let late = monotonicTail && visibleResiduals[last - 2] <= 0.12 && visibleResiduals[last - 1] <= 0.08
                && visibleResiduals[last] == 0 && terminalBounds
            // At these middle states the left side has moved well away from the
            // idle line. Sample outside text content; missing/fixed-idle rails cannot pass.
            func movingChroma(_ pixels: [Double], progress: Double) -> Double {
                let native = geometry.frame(progress: progress), rect = geometry.contourRect(progress: progress)
                let point = CGPoint(x: native.minX + rect.minX + 12 * progress + 2,
                    y: native.maxY - rect.height / 2)
                let width = Int(canvas.width * CGFloat(scale)), height = Int(canvas.height * CGFloat(scale))
                let cx = Int((point.x - canvas.minX) * CGFloat(scale)), cy = Int((canvas.maxY - point.y) * CGFloat(scale))
                var peak = 0.0
                for y in max(0, cy - 2 * scale)...min(height - 1, cy + 2 * scale) {
                    for x in max(0, cx - 2 * scale)...min(width - 1, cx + 2 * scale) {
                        let i = (y * width + x) * 4
                        peak = max(peak, max(pixels[i], max(pixels[i + 1], pixels[i + 2])) - min(pixels[i], min(pixels[i + 1], pixels[i + 2])))
                    }
                }
                return peak
            }
            let halfChroma = movingChroma(scenes[0], progress: 0.5)
            let thirdChroma = movingChroma(scenes[1], progress: 0.3)
            let absentChroma = movingChroma([Double](repeating: 0, count: idle.count), progress: 0.5)
            let movingRail = halfChroma > 0.02 && thirdChroma > halfChroma * 1.1 && absentChroma == 0
            var paired = true
            for index in 0...1 {
                let measurement = pairedSide(scenes[index], scale: scale, progress: progressPoints[index])
                // Shift RGB by three points while leaving the body's alpha unchanged:
                // this recreates a rail/body phase disagreement in the same detector.
                var fault = scenes[index]
                let width = Int(canvas.width * CGFloat(scale)), height = Int(canvas.height * CGFloat(scale))
                for y in 0..<height { for x in 0..<width {
                    let destination = (y * width + x) * 4
                    for channel in 0..<3 {
                        fault[destination + channel] = x >= 3 * scale
                            ? scenes[index][(y * width + x - 3 * scale) * 4 + channel] : 0
                    }
                } }
                let faultMeasurement = pairedSide(fault, scale: scale, progress: progressPoints[index])
                let valid = coherentSide(measurement, scale: scale)
                    && !coherentSide(faultMeasurement, scale: scale)
                paired = paired && valid
                SmokeDiagnostics.mark("collapse paired-body-rail theme=\(themes[replayTheme].rawValue) scale=\(scale) progress=\(progressPoints[index]) bodyRailErrors=\(String(describing: measurement)) shiftedRailErrors=\(String(describing: faultMeasurement)) valid=\(valid) replayNotScanout=true")
            }
            SmokeDiagnostics.mark("collapse shared-contour middle theme=\(themes[replayTheme].rawValue) scale=\(scale) p50Chroma=\(halfChroma) p30Chroma=\(thirdChroma) missingRailRejected=\(absentChroma <= 0.02) movingFade=\(movingRail)")
            let missing = [Double](repeating: 0, count: idle.count)
            var rectangle = idle
            let area = canvas, width = Int(area.width * CGFloat(scale)), height = Int(area.height * CGFloat(scale))
            for y in 0..<height { for x in 0..<width {
                let gx = area.minX + (CGFloat(x) + 0.5) / CGFloat(scale)
                let gy = area.maxY - (CGFloat(y) + 0.5) / CGFloat(scale)
                if geometry.notch.contains(CGPoint(x: gx, y: gy)) { rectangle[(y * width + x) * 4 + 3] = 1 }
            } }
            var shifted = [Double](repeating: 0, count: idle.count)
            for y in 0..<height { for x in scale..<width {
                let destination = (y * width + x) * 4, source = (y * width + x - scale) * 4
                for channel in 0..<4 { shifted[destination + channel] = idle[source + channel] }
            } }
            let missingDelta = normalizedDifference(outsideHardware(missing, scale: scale), visibleIdle, reference: visibleIdle)
            let opaqueDelta = normalizedDifference(rectangle, idle, reference: idle)
            let staleViewportDelta = normalizedDifference(outsideHardware(shifted, scale: scale), visibleIdle, reference: visibleIdle)
            let abruptDelta = normalizedDifference(outsideHardware(scenes[0], scale: scale), visibleIdle, reference: visibleIdle)
            let axes = [geometry.notch.minX - 1, geometry.notch.maxX + 1]
            var terminalAxes = true, shiftedAxesRejected = true
            for axis in axes {
                guard let reference = sideAxis(idle, scale: scale, near: axis),
                      let displaced = sideAxis(shifted, scale: scale, near: axis) else {
                    terminalAxes = false; shiftedAxesRejected = false; continue
                }
                let tolerance = 0.12 / Double(scale)
                let displacement = displaced - reference
                let deltas = scenes.suffix(3).compactMap { sideAxis($0, scale: scale, near: axis).map { $0 - reference } }
                let stable = deltas.count == 3 && deltas.allSatisfy { abs($0) <= tolerance }
                let rejected = abs(displacement - 1) < 0.05 && abs(displacement) > tolerance
                terminalAxes = terminalAxes && stable; shiftedAxesRejected = shiftedAxesRejected && rejected
                SmokeDiagnostics.mark("collapse side-axis theme=\(themes[replayTheme].rawValue) scale=\(scale) expectedBand=\(axis) terminalDeltas=\(deltas) onePointFaultDelta=\(displacement) stable=\(stable) shiftedRejected=\(rejected)")
            }
            let controls = missingDelta > 0.12 && opaqueDelta > 0.12 && shiftedAxesRejected && abruptDelta > 0.12
            passed = late && terminalAxes && controls && movingRail && paired && passed
            SmokeDiagnostics.mark("collapse tail gate theme=\(themes[replayTheme].rawValue) scale=\(scale) late=\(late) terminalBounds=\(terminalBounds) terminalAxes=\(terminalAxes) monotonicTail=\(monotonicTail) controls=\(controls) missing=\(missingDelta) opaque=\(opaqueDelta) staleViewport=\(staleViewportDelta) abruptReplacement=\(abruptDelta) valid=\(late && terminalAxes && controls)")
        }
    }
    private func finish(_ result: Bool) {
        stop()
        print(result ? "COLLAPSE_OK: close-update drain, normal-run-loop bounds and separate common-canvas tail pixels passed; synthetic only" : "COLLAPSE_FAILED: close endpoint evidence failed")
        SmokeDiagnostics.mark("collapse own-view captures=\(captureCount) hardwareScanout=false physicalFeelUnverified=true")
        completion(result)
    }
    func stop() { timer?.invalidate(); timer = nil; controller?.stop() }
}
#endif
