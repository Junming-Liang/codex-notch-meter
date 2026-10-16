#if os(macOS)
import AppKit
import QuartzCore
import NotchCore

/// Own-window observations and separately replayed bitmap samples. Neither is scanout.
@MainActor
final class CollapseRenderHarness: NSObject {
    private let model: MeterModel
    private var geometry: IslandGeometry
    private let originalGeometry: IslandGeometry
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
    private var replayVariant = 0
    private var replayIndex = 0
    private var replayPixels: [Int: [[Double]]] = [:]
    private var intercepted = false
    private var captureCount = 0
    private let progressPoints: [Double] = [0.50, 0.30, 0.10, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001, 0.0005, 0]
    private var themes: [MeterTheme] { MeterTheme.allCases }
    private var replayGeometryLabel: String { ["default", "shortest", "tallest"][replayVariant] }
    private var replayPoints: [Double] { replayVariant == 0 ? progressPoints : [0.001, 0.0005, 0] }
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
        self.model = model; self.geometry = geometry; self.originalGeometry = geometry; self.completion = completion
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
            if replayIndex < replayPoints.count {
                island.setContourTestProgress(replayPoints[replayIndex]); next(20, at: CACurrentMediaTime())
            } else {
                if replayVariant == 0 { inspectReplay(); replayTheme += 1 }
                else { inspectExtremeReplay(); replayVariant += 1 }
                if replayVariant == 0, replayTheme == themes.count { replayVariant = 1; replayTheme = 0 }
                if replayVariant < 3 { startReplay() }
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
        if replayVariant > 0 {
            let base = originalGeometry, frame = base.screen, hardware = base.notch
            guard let notch = NotchGeometry.calculate(screen: frame, topInset: Double(hardware.height),
                auxiliaryLeft: CGRect(x: frame.minX, y: hardware.minY, width: hardware.minX - frame.minX, height: hardware.height),
                auxiliaryRight: CGRect(x: hardware.maxX, y: hardware.minY, width: frame.maxX - hardware.maxX, height: hardware.height)) else {
                finish(false); return
            }
            // Cross the shortest/tallest content endpoints with the opposite depth
            // correction, exercising the smallest/largest remaining bottom travel.
            geometry = IslandGeometry(notch: notch, screen: frame, backingScale: base.backingScale,
                horizontalAdjustment: base.horizontalAdjustment,
                shapeCalibration: ContourCalibration(width: base.shapeCalibration.width,
                    depth: replayVariant == 1 ? 6 : -6, corner: base.shapeCalibration.corner),
                contentHeight: replayVariant == 1 ? 132 : 340)
        }
        model.theme = themes[replayTheme]; model.setContourFixture(left: 83, right: 38)
        SmokeDiagnostics.mark("collapse replay fixture=\(replayGeometryLabel) contentHeight=\(geometry.contentHeight) depthCorrection=\(geometry.shapeCalibration.depth) offlineReplay=true scanout=false")
        controller = IslandPanelController(model: model, geometry: geometry, startPolling: false,
            reducedMotionOverride: false, hovered: {}, refresh: {}, settings: {}, quit: {})
        controller?.setContourTestProgress(replayPoints[0]); next(20, at: CACurrentMediaTime())
    }
    private var canvas: CGRect {
        let frame = geometry.frame(progress: replayVariant == 0 ? 0.5 : 0.001)
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
            if phase == 20 && replayVariant == 0 && replayIndex < 2 {
                passed = IslandPaintParity.check(current: bitmap, model: model, geometry: geometry,
                    progress: progressPoints[replayIndex]) && passed
            }
            let expectedWidth = Int(ceil(view.bounds.width * CGFloat(scale)))
            let expectedHeight = Int(ceil(view.bounds.height * CGFloat(scale)))
            guard bitmap.representation.pixelsWide == expectedWidth, bitmap.representation.pixelsHigh == expectedHeight else { continue }
            captureCount += 1
            if phase == 20, replayVariant == 0, [0.3, 0.02].contains(replayPoints[replayIndex]) {
                saveDiagnosticBitmap(bitmap, name: "current-\(themes[replayTheme].rawValue)-p\(replayPoints[replayIndex])-\(scale)x")
            }
            result[scale] = commonCanvas(bitmap, frame: island.panel.frame)
        }
        return result
    }
    /// Optional, bounded artifacts contain only this synthetic own-view replay.
    private func saveDiagnosticBitmap(_ bitmap: NativeContourBitmap, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["CODEX_COLLAPSE_ARTIFACT_DIR"] else { return }
        do {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let png = bitmap.representation.representation(using: .png, properties: [:]) else {
                SmokeDiagnostics.mark("collapse diagnostic PNG name=\(name) encoded=false"); return
            }
            try png.write(to: folder.appendingPathComponent(name + ".png"))
            SmokeDiagnostics.mark("collapse diagnostic PNG name=\(name) saved=true ownViewOnly=true scanout=false")
        } catch {
            SmokeDiagnostics.mark("collapse diagnostic PNG name=\(name) saved=false error=\(error)")
        }
    }
    /// Both production and rendered negative controls use this exact global canvas.
    private func commonCanvas(_ bitmap: NativeContourBitmap, frame: CGRect) -> [Double] {
        let scale = bitmap.scale, area = canvas
        let width = Int(area.width * CGFloat(scale)), height = Int(area.height * CGFloat(scale))
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
        return values
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
        let threshold = geometry.surfaceOpacity(progress: progress) * 0.5
        guard threshold.isFinite, threshold > 0 else { return nil }
        var bodyEdges: [Double] = [], colorWeight = 0.0, colorX = 0.0
        for y in 0..<height {
            let globalY = canvas.maxY - (CGFloat(y) + 0.5) / CGFloat(scale)
            guard abs(native.maxY - globalY - depth) <= 3 else { continue }
            var first: Double?
            var previous: (x: Double, alpha: Double)?
            for x in 0..<width {
                let gx = canvas.minX + (CGFloat(x) + 0.5) / CGFloat(scale)
                guard gx >= side - 3, gx <= side + 6 else { continue }
                let index = (y * width + x) * 4
                let alpha = pixels[index + 3]
                guard alpha.isFinite else { return nil }
                // A partially covered boundary pixel may lie just below50%.
                // Interpolate its bracket instead of jumping one pixel center.
                if first == nil, let previous, previous.alpha <= threshold, alpha > threshold {
                    let fraction = (threshold - previous.alpha) / (alpha - previous.alpha)
                    first = previous.x + (Double(gx) - previous.x) * fraction
                }
                previous = (Double(gx), alpha)
                let chroma = max(pixels[index], max(pixels[index + 1], pixels[index + 2]))
                    - min(pixels[index], min(pixels[index + 1], pixels[index + 2]))
                colorWeight += chroma; colorX += Double(gx) * chroma
            }
            guard let first, first.isFinite else { return nil }
            bodyEdges.append(first)
        }
        guard !bodyEdges.isEmpty, colorWeight > 0.1 else { return nil }
        return (bodyEdges.reduce(0, +) / Double(bodyEdges.count) - Double(side),
            colorX / colorWeight - Double(side + 2))
    }
    /// Diagnostic only: expose every sample and footprint in each failing side row.
    private func logPairedSideRows(_ pixels: [Double], scale: Int, progress: Double) {
        let native = geometry.frame(progress: progress), rect = geometry.contourRect(progress: progress)
        let side = native.minX + rect.minX + CGFloat(12 * progress), depth = rect.height / 2
        let width = Int(canvas.width * CGFloat(scale)), height = Int(canvas.height * CGFloat(scale))
        let halfPixel = 0.5 / CGFloat(scale), threshold = geometry.surfaceOpacity(progress: progress) * 0.5
        guard pixels.count == width * height * 4 else { return }
        for y in 0..<height {
            let gy = canvas.maxY - (CGFloat(y) + 0.5) / CGFloat(scale)
            guard abs(native.maxY - gy - depth) <= 3 else { continue }
            var samples: [String] = []
            for x in 0..<width {
                let gx = canvas.minX + (CGFloat(x) + 0.5) / CGFloat(scale)
                guard gx >= side - 3, gx <= side + 6 else { continue }
                let i = (y * width + x) * 4
                let chroma = max(pixels[i], max(pixels[i + 1], pixels[i + 2]))
                    - min(pixels[i], min(pixels[i + 1], pixels[i + 2]))
                samples.append("x:\(gx),footprint:[\(gx - halfPixel),\(gx + halfPixel)],alpha:\(pixels[i + 3]),chroma:\(chroma)")
            }
            SmokeDiagnostics.mark("collapse paired-alpha-row theme=\(themes[replayTheme].rawValue) scale=\(scale) progress=\(progress) expectedSide=\(side) threshold=\(threshold) globalY=\(gy) yFootprint=[\(gy - halfPixel),\(gy + halfPixel)] samples=\(samples) diagnosticOnly=true scanout=false")
        }
    }
    private func coherentSide(_ measurement: (body: Double, rail: Double)?, scale: Int) -> Bool {
        guard let measurement else { return false }
        return abs(measurement.body) <= 1 / Double(scale)
            && abs(measurement.rail) <= 0.6 / Double(scale)
    }
    /// Recover the drawing contour in one global top-down space, independently of
    /// the production opacity API and native viewport rounding.
    private func globalContour(progress: Double) -> IslandContour {
        let frame = geometry.frame(progress: progress), rect = geometry.contourRect(progress: progress)
        return IslandContour(rect: CGRect(x: frame.minX + rect.minX,
            y: geometry.screen.maxY - frame.maxY + rect.minY, width: rect.width, height: rect.height),
            progress: progress, cornerAdjustment: geometry.shapeCalibration.corner, referenceDepth: geometry.notch.height)
    }
    private func measuredContourResidual(progress: Double) -> Double {
        let current = globalContour(progress: progress), idle = globalContour(progress: 0)
        let bottom: CGFloat = abs(current.rect.maxY - idle.rect.maxY)
        let leftSide: CGFloat = abs(current.rect.minX + current.shoulder - idle.rect.minX - idle.shoulder)
        let rightSide: CGFloat = abs(current.rect.maxX - current.shoulder - idle.rect.maxX + idle.shoulder)
        let leftBound: CGFloat = abs(current.bounds.minX - idle.bounds.minX)
        let rightBound: CGFloat = abs(current.bounds.maxX - idle.bounds.maxX)
        let lowerCorner: CGFloat = abs(current.corner - idle.corner)
        let upperCorner: CGFloat = abs(current.upperCorner - idle.upperCorner)
        let distances: [CGFloat] = [bottom, leftSide, rightSide, leftBound, rightBound, lowerCorner, upperCorner]
        return Double(distances.max() ?? CGFloat.infinity)
    }
    private func expectedBodyAlpha(residual: Double) -> Double {
        let t = min(1, max(0, residual / 4))
        return t * t * (3 - 2 * t)
    }
    private struct BodyCoverage {
        var count = 0
        var sum = 0.0
        var minimum = 1.0
        var maximum = 0.0
        var color = 0.0
        var chroma = 0.0
        var sampleBounds = CGRect.null
        var rows: [String] = []
        var mean: Double { count > 0 ? sum / Double(count) : .infinity }
        func matches(_ expected: Double, scale: Int) -> Bool {
            count >= 32 * scale && abs(mean - expected) <= 0.012
                && minimum >= expected - 0.015 && maximum <= expected + 0.015 && color <= 0.015
        }
    }
    /// Middle body samples keep their full pixel footprint at least1pt inside
    /// the rail's nominal inner edge (bottom minus4pt). They use a
    /// two-point band immediately below the camera, so hidden camera pixels cannot
    /// make an already-vanished visible black body pass. Endpoint samples inspect
    /// the broad central interior, which must be exactly transparent at idle.
    private func bodyCoverage(_ pixels: [Double], scale: Int, progress: Double, outsideCamera: Bool) -> BodyCoverage {
        let area = canvas, contour = globalContour(progress: progress)
        let width = Int(area.width * CGFloat(scale)), height = Int(area.height * CGFloat(scale))
        var result = BodyCoverage()
        guard pixels.count == width * height * 4 else { return result }
        for y in 0..<height {
            let gy = area.maxY - (CGFloat(y) + 0.5) / CGFloat(scale)
            let depth = geometry.screen.maxY - gy
            if outsideCamera {
                guard gy < geometry.notch.minY - 0.25, gy >= geometry.notch.minY - 2.25,
                      depth + 0.5 / CGFloat(scale) <= contour.rect.maxY - 5 else { continue }
            } else {
                guard depth > contour.rect.minY + 4.25, depth < contour.rect.maxY - 4.25 else { continue }
            }
            var rowCount = 0, rowSum = 0.0, rowMinimum = 1.0, rowMaximum = 0.0, rowColor = 0.0, rowChroma = 0.0
            for x in 0..<width {
                let gx = area.minX + (CGFloat(x) + 0.5) / CGFloat(scale)
                if outsideCamera {
                    guard abs(gx - geometry.notch.midX) <= min(32, geometry.notch.width / 4),
                          !geometry.notch.contains(CGPoint(x: gx, y: gy)) else { continue }
                } else {
                    guard gx > contour.rect.minX + contour.shoulder + contour.corner + 4.25,
                          gx < contour.rect.maxX - contour.shoulder - contour.corner - 4.25 else { continue }
                }
                let offset = (y * width + x) * 4, alpha = pixels[offset + 3]
                result.count += 1; result.sum += alpha
                result.minimum = min(result.minimum, alpha); result.maximum = max(result.maximum, alpha)
                let color = max(pixels[offset], max(pixels[offset + 1], pixels[offset + 2]))
                let chroma = color - min(pixels[offset], min(pixels[offset + 1], pixels[offset + 2]))
                result.color = max(result.color, color); result.chroma = max(result.chroma, chroma)
                if outsideCamera {
                    let pixelSize = 1 / CGFloat(scale), halfPixel = pixelSize / 2
                    result.sampleBounds = result.sampleBounds.union(CGRect(x: gx - halfPixel, y: gy - halfPixel,
                        width: pixelSize, height: pixelSize))
                    rowCount += 1; rowSum += alpha; rowMinimum = min(rowMinimum, alpha); rowMaximum = max(rowMaximum, alpha)
                    rowColor = max(rowColor, color); rowChroma = max(rowChroma, chroma)
                }
            }
            if outsideCamera, rowCount > 0 {
                let halfPixel = 0.5 / CGFloat(scale), railInnerDepth = contour.rect.maxY - 4
                result.rows.append("depth:\(depth),globalY:\(gy),depthFootprint:[\(depth - halfPixel),\(depth + halfPixel)],railFootprintGap:\(railInnerDepth - depth - halfPixel),count:\(rowCount),mean:\(rowSum / Double(rowCount)),min:\(rowMinimum),max:\(rowMaximum),color:\(rowColor),chroma:\(rowChroma)")
            }
        }
        return result
    }
    private func inspectBodyCoupling(scenes: [[Double]], scale: Int) {
        for index in 2...4 {
            let progress = progressPoints[index], residual = measuredContourResidual(progress: progress)
            let expected = expectedBodyAlpha(residual: residual)
            let current = bodyCoverage(scenes[index], scale: scale, progress: progress, outsideCamera: true)
            guard let orientation = rowOrientation[scale],
                  let reference = IslandPaintParity.captureReference(model: model, geometry: geometry, progress: progress,
                    scale: scale, topRowFirst: orientation, legacySurface: true) else {
                passed = false
                SmokeDiagnostics.mark("collapse coupled-body theme=\(themes[replayTheme].rawValue) scale=\(scale) progress=\(progress) referenceCapture=false valid=false")
                continue
            }
            captureCount += 1
            if progress == 0.02 {
                saveDiagnosticBitmap(reference, name: "legacy-\(themes[replayTheme].rawValue)-p\(progress)-\(scale)x")
            }
            let oldPixels = commonCanvas(reference, frame: geometry.frame(progress: progress))
            let old = bodyCoverage(oldPixels, scale: scale, progress: progress, outsideCamera: true)
            let oldT = min(1, progress * 3), oldExpected = oldT * oldT * (3 - 2 * oldT)
            let legacyRendered = old.count == current.count && old.matches(oldExpected, scale: scale)
            let legacyRejected = legacyRendered && !old.matches(expected, scale: scale) && expected - old.mean > 0.5
            let residualAgrees = abs(residual - geometry.contourResidual(progress: progress)) < 0.0000001
            let valid = residualAgrees && expected >= 0.95 && current.matches(expected, scale: scale) && legacyRejected
            passed = valid && passed
            if progress == 0.02 {
                SmokeDiagnostics.mark("collapse body-band-samples theme=\(themes[replayTheme].rawValue) scale=\(scale) progress=\(progress) globalFootprintBounds=\(current.sampleBounds) oldGlobalFootprintBounds=\(old.sampleBounds) oldMinimum=\(old.minimum) oldMaximum=\(old.maximum) oldMaxColor=\(old.color) oldMaxChroma=\(old.chroma) currentRows=\(current.rows) oldRows=\(old.rows) diagnosticOnly=true scanout=false")
            }
            SmokeDiagnostics.mark("collapse coupled-body theme=\(themes[replayTheme].rawValue) scale=\(scale) progress=\(progress) contourResidualPoints=\(residual) expectedAlpha=\(expected) samples=\(current.count) meanAlpha=\(current.mean) minAlpha=\(current.minimum) maxAlpha=\(current.maximum) oldRenderedAlpha=\(old.mean) legacyRendered=\(legacyRendered) legacyRejected=\(legacyRejected) valid=\(valid) outsideCamera=true offlineReplay=true scanout=false")
        }
    }
    private func inspectBodyEndpoint(scenes: [[Double]], scale: Int) {
        guard scenes.count == 3 else { passed = false; return }
        for (index, progress) in [0.001, 0.0005, 0.0].enumerated() {
            let residual = measuredContourResidual(progress: progress)
            let expected = expectedBodyAlpha(residual: residual)
            let body = bodyCoverage(scenes[index], scale: scale, progress: progress, outsideCamera: false)
            let maximumAllowed = progress == 0 ? 0 : (progress == 0.001 ? 0.026 : 0.008)
            let transparentIdle = progress != 0 || (body.minimum == 0 && body.maximum == 0 && body.mean == 0)
            let valid = abs(residual - geometry.contourResidual(progress: progress)) < 0.0000001
                && residual <= 0.3510001 && abs(body.mean - expected) <= 0.006
                && body.matches(expected, scale: scale) && body.maximum <= maximumAllowed && transparentIdle
            passed = valid && passed
            SmokeDiagnostics.mark("collapse body-endpoint fixture=\(replayGeometryLabel) theme=\(themes[replayTheme].rawValue) scale=\(scale) progress=\(progress) contourResidualPoints=\(residual) expectedAlpha=\(expected) samples=\(body.count) meanAlpha=\(body.mean) maxAlpha=\(body.maximum) transparentIdle=\(transparentIdle) valid=\(valid) offlineReplay=true scanout=false")
        }
    }
    private func inspectExtremeReplay() {
        for scale in [1, 2] {
            guard let scenes = replayPixels[scale], scenes.count == 3, let idle = scenes.last else { passed = false; continue }
            inspectBodyEndpoint(scenes: scenes, scale: scale)
            let visibleIdle = outsideHardware(idle, scale: scale)
            let residuals = scenes.map { normalizedDifference(outsideHardware($0, scale: scale), visibleIdle, reference: visibleIdle) }
            let idleBounds = paintedBounds(visibleIdle, scale: scale)
            let terminalBounds = scenes.allSatisfy { pixels in
                guard let first = paintedBounds(outsideHardware(pixels, scale: scale), scale: scale), let second = idleBounds else { return false }
                return abs(first.minX - second.minX) <= 1 / CGFloat(scale)
                    && abs(first.maxX - second.maxX) <= 1 / CGFloat(scale)
                    && abs(first.minY - second.minY) <= 1 / CGFloat(scale)
                    && abs(first.maxY - second.maxY) <= 1 / CGFloat(scale)
            }
            let terminalAxes = [geometry.notch.minX - 1, geometry.notch.maxX + 1].allSatisfy { axis in
                guard let reference = sideAxis(idle, scale: scale, near: axis) else { return false }
                return scenes.allSatisfy { pixels in
                    guard let current = sideAxis(pixels, scale: scale, near: axis) else { return false }
                    return abs(current - reference) <= 0.12 / Double(scale)
                }
            }
            // Retain the default replay's existing terminal tolerances, including
            // the same outside-camera exclusion and one-physical-pixel bound budget.
            let valid = residuals[0] <= 0.12 && residuals[1] <= 0.08 && residuals[2] == 0
                && residuals[1] <= residuals[0] + 0.015 && terminalBounds && terminalAxes
            passed = valid && passed
            SmokeDiagnostics.mark("collapse extreme-tail fixture=\(replayGeometryLabel) scale=\(scale) outsideExclusionDifferences=\(residuals) terminalBounds=\(terminalBounds) terminalAxes=\(terminalAxes) valid=\(valid) offlineReplay=true scanout=false")
        }
    }
    private func inspectReplay() {
        for scale in [1, 2] {
            guard let scenes = replayPixels[scale], scenes.count == progressPoints.count, let idle = scenes.last else { passed = false; continue }
            inspectBodyCoupling(scenes: scenes, scale: scale)
            inspectBodyEndpoint(scenes: Array(scenes.suffix(3)), scale: scale)
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
                if !coherentSide(measurement, scale: scale) {
                    logPairedSideRows(scenes[index], scale: scale, progress: progressPoints[index])
                }
                // Shift RGB by three points while leaving the body's alpha unchanged:
                // this recreates a rail/body phase disagreement in the same detector.
                var fault = scenes[index]
                var bodyFault = scenes[index]
                let width = Int(canvas.width * CGFloat(scale)), height = Int(canvas.height * CGFloat(scale))
                for y in 0..<height { for x in 0..<width {
                    let destination = (y * width + x) * 4
                    for channel in 0..<3 {
                        fault[destination + channel] = x >= 3 * scale
                            ? scenes[index][(y * width + x - 3 * scale) * 4 + channel] : 0
                    }
                    // Independent body-position fault: translate alpha only,
                    // leaving the visible rail's color at its original position.
                    bodyFault[destination + 3] = x >= 3 * scale
                        ? scenes[index][(y * width + x - 3 * scale) * 4 + 3] : 0
                } }
                let faultMeasurement = pairedSide(fault, scale: scale, progress: progressPoints[index])
                let bodyFaultMeasurement = pairedSide(bodyFault, scale: scale, progress: progressPoints[index])
                let railShiftRejected = !coherentSide(faultMeasurement, scale: scale)
                let bodyShiftRejected = !coherentSide(bodyFaultMeasurement, scale: scale)
                let valid = coherentSide(measurement, scale: scale)
                    && railShiftRejected && bodyShiftRejected
                paired = paired && valid
                SmokeDiagnostics.mark("collapse paired-body-rail theme=\(themes[replayTheme].rawValue) scale=\(scale) progress=\(progressPoints[index]) bodyRailErrors=\(String(describing: measurement)) shiftedRailErrors=\(String(describing: faultMeasurement)) shiftedBodyErrors=\(String(describing: bodyFaultMeasurement)) railShiftRejected=\(railShiftRejected) bodyShiftRejected=\(bodyShiftRejected) valid=\(valid) replayNotScanout=true")
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
        print(result ? "COLLAPSE_OK: close-update drain, coupled body coverage, rendered old-fade rejection and common-canvas tail pixels passed; synthetic offline replay, not scanout" : "COLLAPSE_FAILED: close endpoint evidence failed")
        SmokeDiagnostics.mark("collapse own-view captures=\(captureCount) hardwareScanout=false physicalFeelUnverified=true")
        completion(result)
    }
    func stop() { timer?.invalidate(); timer = nil; controller?.stop() }
}
#endif
