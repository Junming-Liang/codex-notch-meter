#if os(macOS)
import AppKit
import SwiftUI
import NotchCore

/// Own-view bitmap evidence only. Never captures the desktop, other windows, or an account.
@MainActor
private final class ScaleCalibrationView: NSView {
    private(set) var drawingScale: CGSize = .zero
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        if let transform = NSGraphicsContext.current?.cgContext.ctm {
            drawingScale = CGSize(width: abs(transform.a), height: abs(transform.d))
        }
        NSColor.red.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2).fill()
        NSColor.blue.setFill(); NSRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 2).fill()
    }
}

private struct ContourPixel {
    var r: Double, g: Double, b: Double, a: Double
    var chromatic: Bool { a > 0.2 && max(r, max(g, b)) - min(r, min(g, b)) > 0.12 }
    var light: Double { (r + g + b) / 3 }
}

@MainActor
private struct NativeContourBitmap {
    let representation: NSBitmapImageRep
    let size: CGSize
    let scale: Int
    let topRowFirst: Bool
    static func capture(_ view: NSView, scale: Int, topRowFirst: Bool) -> NativeContourBitmap? {
        let size = view.bounds.size
        let width = size.width * CGFloat(scale), height = size.height * CGFloat(scale)
        guard width > 0, height > 0, width.isFinite, height.isFinite,
              abs(width - width.rounded()) < 0.001, abs(height - height.rounded()) < 0.001 else { return nil }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(width.rounded()), pixelsHigh: Int(height.rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // This is a real scale-specific backing context, not a resized 1x image.
        bitmap.size = size
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return NativeContourBitmap(representation: bitmap, size: size, scale: scale, topRowFirst: topRowFirst)
    }
    func pixel(x: Int, y: Int) -> ContourPixel {
        let row = topRowFirst ? y : representation.pixelsHigh - 1 - y
        guard let color = representation.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB) else {
            return ContourPixel(r: 0, g: 0, b: 0, a: 0)
        }
        return ContourPixel(r: color.redComponent, g: color.greenComponent, b: color.blueComponent, a: color.alphaComponent)
    }
    func near(_ point: CGPoint, transform: (ContourPixel) -> ContourPixel = { $0 }) -> [ContourPixel] {
        let radius = max(1, scale)
        let x = Int(point.x * CGFloat(scale)), y = Int(point.y * CGFloat(scale))
        return (-radius...radius).flatMap { dy in
            (-radius...radius).compactMap { dx -> ContourPixel? in
                let xx = x + dx, yy = y + dy
                guard xx >= 0, yy >= 0, xx < representation.pixelsWide, yy < representation.pixelsHigh else { return nil }
                return transform(pixel(x: xx, y: yy))
            }
        }
    }
    func export(name: String, hardware: CGSize) throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEX_CONTOUR_ARTIFACT_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let raw = representation.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try raw.write(to: folder.appendingPathComponent("demo-\(name)-\(scale)x-transparent.png"))
        // Native composition for inspection: plain backdrop, explicit synthetic cutout, real view pixels.
        for dark in [false, true] {
            let canvasSize = CGSize(width: size.width + 32, height: size.height + 48)
            guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int((canvasSize.width * CGFloat(scale)).rounded()), pixelsHigh: Int((canvasSize.height * CGFloat(scale)).rounded()),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: canvas) else { throw CocoaError(.fileWriteUnknown) }
            canvas.size = canvasSize
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)).setFill()
            CGRect(origin: .zero, size: canvasSize).fill()
            let image = NSImage(size: size); image.addRepresentation(representation)
            image.draw(in: CGRect(x: 16, y: 32, width: size.width, height: size.height))
            // Occlude with the system-provided bounding-region approximation, not a claimed physical mask.
            NSColor.black.setFill()
            NSBezierPath(roundedRect: CGRect(x: canvasSize.width / 2 - hardware.width / 2,
                y: 32 + size.height - hardware.height, width: hardware.width, height: hardware.height + 8),
                xRadius: 8, yRadius: 8).fill()
            let title = "DEMO · native \(scale)x offscreen · synthetic cutout"
            (title as NSString).draw(at: CGPoint(x: 8, y: 10), withAttributes: [
                .font: NSFont.systemFont(ofSize: 8), .foregroundColor: dark ? NSColor.white : NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            guard let png = canvas.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: folder.appendingPathComponent("demo-\(name)-\(scale)x-\(dark ? "dark" : "light").png"))
        }
    }
}

private struct ContourMetrics {
    let valid: Bool
    let colors: [Double]
    let track: [Double]
    let brightness: Double
    let failures: [String]
}

private struct LegacyExtentPreference: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct LegacyRailShape: Shape {
    let left: Bool
    func path(in rect: CGRect) -> Path {
        let edge: CGFloat = left ? 3 : rect.width - 3
        let direction: CGFloat = left ? 1 : -1
        var path = Path(); path.move(to: CGPoint(x: edge, y: 0))
        path.addLine(to: CGPoint(x: edge, y: rect.height - 10))
        path.addQuadCurve(to: CGPoint(x: edge + direction * 7, y: rect.height - 3), control: CGPoint(x: edge, y: rect.height - 3))
        path.addLine(to: CGPoint(x: left ? rect.width : 0, y: rect.height - 3))
        return path
    }
}

private struct LegacySilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(); let radius = min(CGFloat(8), rect.height / 2)
        path.move(to: .zero); path.addLine(to: CGPoint(x: 0, y: rect.height - radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: rect.height), control: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width - radius, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: rect.height - radius), control: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width, y: 0)); path.closeSubpath(); return path
    }
}

/// Reproduces the v0.1.1 layout mechanism for diagnosis, never used by the normal UI.
@MainActor
private struct LegacyLayoutFixture: View {
    @ObservedObject var model: MeterModel
    let extent: (CGSize) -> Void
    var body: some View {
        ZStack(alignment: .top) {
            LegacySilhouette().fill(.black)
                .background(GeometryReader { proxy in Color.clear.preference(key: LegacyExtentPreference.self, value: proxy.size) })
            HStack(spacing: 0) {
                ForEach([true, false], id: \.self) { left in
                    ZStack {
                        LegacyRailShape(left: left).stroke(.black.opacity(0.9), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        LegacyRailShape(left: left).stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        LegacyRailShape(left: left).stroke(Color(red: 0.44, green: 0.84, blue: 0.69), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                }
            }.frame(width: 232, height: 39)
            DetailView(model: model, embedded: true, embeddedHeight: 472, hovered: { _ in }, refresh: {}, settings: {}, quit: {})
                .padding(.top, 40).opacity(0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(LegacySilhouette()).clipped().ignoresSafeArea(.all)
        .onPreferenceChange(LegacyExtentPreference.self, perform: extent)
    }
}

@MainActor
private enum ContourPixelGate {
    /// Independent polyline sampling of the design contract, not the production SwiftUI Path.
    static func arcPoint(_ fraction: Double, left: Bool, size: CGSize) -> CGPoint {
        var points = [CGPoint(x: 2, y: 0), CGPoint(x: 2, y: size.height - 12)]
        for step in 1...100 {
            let t = CGFloat(step) / 100
            points.append(CGPoint(x: 2 + 10 * t * t, y: size.height - 12 + 20 * t - 10 * t * t))
        }
        points.append(CGPoint(x: size.width / 2 - 2, y: size.height - 2))
        let lengths = zip(points, points.dropFirst()).map { pair in hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y) }
        var distance = CGFloat(fraction) * lengths.reduce(0, +)
        var result = points.last!
        for (index, length) in lengths.enumerated() {
            if distance <= length {
                let t = length > 0 ? distance / length : 0
                result = CGPoint(x: points[index].x + (points[index + 1].x - points[index].x) * t,
                    y: points[index].y + (points[index + 1].y - points[index].y) * t)
                break
            }
            distance -= length
        }
        if !left { result.x = size.width - result.x }
        return result
    }
    static func inspect(_ bitmap: NativeContourBitmap, hardware: CGRect, fractions: [Double?],
                        transform: (ContourPixel) -> ContourPixel = { $0 }) -> ContourMetrics {
        let size = bitmap.size
        let corners = [CGPoint(x: 0.5, y: size.height - 0.5), CGPoint(x: 2.5, y: size.height - 0.5),
                       CGPoint(x: 0.5, y: size.height - 2.5), CGPoint(x: size.width - 0.5, y: size.height - 0.5),
                       CGPoint(x: size.width - 2.5, y: size.height - 0.5)]
        let transparent = corners.allSatisfy { point in
            let p = transform(bitmap.pixel(x: Int(point.x * CGFloat(bitmap.scale)), y: Int(point.y * CGFloat(bitmap.scale))))
            return p.a < 0.05
        }
        let interior = transform(bitmap.pixel(x: bitmap.representation.pixelsWide / 2, y: 8 * bitmap.scale)).a < 0.05
        var colors = [0.0, 0.0], track = [0.0, 0.0], light = 0.0, lightCount = 0.0
        for y in 0..<bitmap.representation.pixelsHigh {
            for x in 0..<bitmap.representation.pixelsWide {
                let px = CGFloat(x) / CGFloat(bitmap.scale), py = CGFloat(y) / CGFloat(bitmap.scale)
                // Only observable area outside the simulated rectangular camera exclusion counts.
                guard !hardware.contains(CGPoint(x: px, y: py)) else { continue }
                let pixel = transform(bitmap.pixel(x: x, y: y)); let side = px < size.width / 2 ? 0 : 1
                if pixel.chromatic { colors[side] += 1; light += pixel.light; lightCount += 1 }
                if pixel.a > 0.2 && pixel.light > 0.12 { track[side] += 1 }
            }
        }
        var samplesValid = true
        var failures: [String] = []
        if !transparent { failures.append("opaque-corner") }; if !interior { failures.append("opaque-interior") }
        for side in 0...1 {
            if let percent = fractions[side] {
                // Dense 5% probes plus explicit boundary probes, outside cap/AA uncertainty.
                let probes = stride(from: 0.05, through: 0.95, by: 0.05).map { $0 }
                    + [percent / 100 - 0.055, percent / 100 + 0.055].filter { $0 > 0 && $0 < 1 }
                for location in probes where abs(location - percent / 100) > 0.045 {
                    let point = arcPoint(location, left: side == 0, size: size)
                    let colored = bitmap.near(point, transform: transform).contains { $0.chromatic }
                    if colored != (location < percent / 100) { failures.append("rail\(side)-arc\(location)-colored\(colored)") }
                    samplesValid = samplesValid && (colored == (location < percent / 100))
                }
                if percent > 0 { samplesValid = samplesValid && colors[side] > 15 * Double(bitmap.scale * bitmap.scale) }
                else { samplesValid = samplesValid && colors[side] < 10 * Double(bitmap.scale * bitmap.scale) }
            } else {
                samplesValid = samplesValid && colors[side] < 2 * Double(bitmap.scale * bitmap.scale)
                let levels = (5..<95).map { step in
                    bitmap.near(arcPoint(Double(step) / 100, left: side == 0, size: size), transform: transform)
                        .map(\.light).max() ?? 0
                }
                samplesValid = samplesValid && (levels.max() ?? 0) - (levels.min() ?? 0) > 0.15
            }
            if !samplesValid { failures.append("rail\(side)-coverage") }
            if track[side] <= 30 * Double(bitmap.scale * bitmap.scale) { failures.append("rail\(side)-track") }
            samplesValid = samplesValid && track[side] > 30 * Double(bitmap.scale * bitmap.scale)
        }
        return ContourMetrics(valid: transparent && interior && samplesValid,
            colors: colors.map { $0 / Double(bitmap.scale * bitmap.scale) },
            track: track.map { $0 / Double(bitmap.scale * bitmap.scale) }, brightness: lightCount > 0 ? light / lightCount : 0, failures: failures)
    }
}

/// Native rendering-state regression. All scenes update one live demo MeterModel.
@MainActor
final class ContourRenderHarness: NSObject {
    private struct Scene {
        let name: String, left: Double?, right: Double?
        var stale = false, pending = false, expanded = false
    }
    private let scenes: [Scene] = [
        Scene(name: "full", left: 100, right: 100), Scene(name: "eighty-three", left: 83, right: 83),
        Scene(name: "quarter", left: 25, right: 25), Scene(name: "zero", left: 0, right: 0),
        Scene(name: "unknown", left: nil, right: nil), Scene(name: "stale", left: 83, right: 83, stale: true),
        Scene(name: "reset-pending", left: 83, right: 83, pending: true), Scene(name: "mixed", left: 25, right: 83),
        Scene(name: "updated-full", left: 100, right: 100), Scene(name: "expanded", left: 83, right: 83, expanded: true),
        Scene(name: "recollapsed", left: 100, right: 100)
    ]
    private let model: MeterModel
    private let island: IslandPanelController
    private let completion: (Bool) -> Void
    private var timer: Timer?
    private var sceneIndex = 0
    private var passed = true
    private var orientations: [Int: Bool] = [:]
    private var results: [String: [Int: ContourMetrics]] = [:]
    private var legacyPanel: TopEdgePanel?
    private var legacyExtent: CGSize = .zero
    init(model: MeterModel, island: IslandPanelController, completion: @escaping (Bool) -> Void) {
        self.model = model; self.island = island; self.completion = completion
    }
    func start() {
        for scale in [1, 2] {
            let calibration = ScaleCalibrationView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
            guard let raw = NativeContourBitmap.capture(calibration, scale: scale, topRowFirst: true) else { passed = false; continue }
            let top = raw.pixel(x: scale * 2, y: scale), bottom = raw.pixel(x: scale * 2, y: 6 * scale)
            let valid = ((top.r > 0.9 && bottom.b > 0.9) || (top.b > 0.9 && bottom.r > 0.9))
                && abs(calibration.drawingScale.width - CGFloat(scale)) < 0.01
                && abs(calibration.drawingScale.height - CGFloat(scale)) < 0.01
            passed = passed && valid && raw.representation.pixelsWide == 8 * scale && raw.representation.pixelsHigh == 8 * scale
            orientations[scale] = top.r > 0.9
            SmokeDiagnostics.mark("contour calibration scale=\(scale) pixels=\(raw.representation.pixelsWide)x\(raw.representation.pixelsHigh) topRowFirst=\(top.r > 0.9) drawingScale=\(calibration.drawingScale) valid=\(valid)")
        }
        setScene()
        // A native diagnostic fixture preserves the old hidden-detail sizing mechanism.
        let frame = CGRect(x: island.geometry.notch.midX - 116, y: island.geometry.screen.maxY - 39, width: 232, height: 39)
        let panel = TopEdgePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        let hosting = NSHostingView(rootView: LegacyLayoutFixture(model: model, extent: { [weak self] in self?.legacyExtent = $0 }))
        hosting.sizingOptions = []; if #available(macOS 14.0, *) { hosting.safeAreaRegions = [] }
        panel.contentView = hosting; panel.setFrame(frame, display: true); panel.orderFrontRegardless()
        legacyPanel = panel
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(captureScene(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func setScene() {
        let scene = scenes[sceneIndex]
        model.setContourFixture(left: scene.left, right: scene.right, stale: scene.stale, pending: scene.pending)
        island.setContourTestProgress(scene.expanded ? 1 : 0)
    }
    @objc private func captureScene(_ timer: Timer) {
        let scene = scenes[sceneIndex]
        guard let view = island.panel.contentView else { finish(false); return }
        if sceneIndex == 0, let legacy = legacyPanel?.contentView {
            SmokeDiagnostics.mark("legacy layout fixture host=\(legacy.bounds.size) silhouette=\(legacyExtent) opaque=\(legacy.isOpaque)")
            for scale in [1, 2] {
                if let bitmap = NativeContourBitmap.capture(legacy, scale: scale, topRowFirst: orientations[scale] ?? true) {
                    do { try bitmap.export(name: "legacy-layout-control", hardware: CGSize(width: 220, height: 32)) } catch { passed = false }
                    let metrics = ContourPixelGate.inspect(bitmap, hardware: CGRect(x: 6, y: 0, width: 220, height: 32), fractions: [100, 100])
                    SmokeDiagnostics.mark("legacy layout fixture scale=\(scale) colorArea=\(metrics.colors) contourContract=\(metrics.valid)")
                }
            }
            legacyPanel?.close(); legacyPanel = nil
        }
        let frame = island.panel.frame, notch = island.geometry.notch
        let hardware = CGRect(x: notch.minX - frame.minX, y: frame.maxY - notch.maxY,
                              width: notch.width, height: notch.height)
        let extensions = [notch.minX - frame.minX, frame.maxX - notch.maxX, notch.minY - frame.minY]
        let envelopeValid = scene.expanded || (extensions.allSatisfy { $0 >= 3 && $0 <= 4 }
            && abs(frame.maxY - island.geometry.screen.maxY) < 0.01)
        passed = passed && envelopeValid
        SmokeDiagnostics.mark("contour hardware scene=\(scene.name) panel=\(frame) localMask=\(hardware) extensions=\(extensions) envelope=\(envelopeValid)")
        let viewportValid = island.renderedViewport == view.bounds.size && !view.isOpaque && island.panel.isOpaque == false
        passed = passed && viewportValid
        SmokeDiagnostics.mark("contour viewport scene=\(scene.name) native=\(view.bounds.size) root=\(island.renderedViewport) opaque=\(view.isOpaque) layerAlpha=\(view.layer?.backgroundColor?.alpha ?? 0) valid=\(viewportValid)")
        for scale in [1, 2] {
            guard let bitmap = NativeContourBitmap.capture(view, scale: scale, topRowFirst: orientations[scale] ?? true) else { passed = false; continue }
            let backingValid = bitmap.representation.pixelsWide == Int(view.bounds.width * CGFloat(scale))
                && bitmap.representation.pixelsHigh == Int(view.bounds.height * CGFloat(scale))
            passed = passed && backingValid
            SmokeDiagnostics.mark("contour backing scene=\(scene.name) scale=\(scale) pixels=\(bitmap.representation.pixelsWide)x\(bitmap.representation.pixelsHigh) points=\(view.bounds.size) valid=\(backingValid)")
            do { try bitmap.export(name: scene.name, hardware: island.geometry.notch.size) } catch { passed = false }
            if scene.expanded { continue }
            let metrics = ContourPixelGate.inspect(bitmap, hardware: hardware, fractions: [scene.left, scene.right])
            results[scene.name, default: [:]][scale] = metrics
            passed = passed && metrics.valid
            SmokeDiagnostics.mark("contour pixels scene=\(scene.name) scale=\(scale) colorArea=\(metrics.colors) trackArea=\(metrics.track) brightness=\(metrics.brightness) valid=\(metrics.valid) failures=\(metrics.failures)")
            if scene.name == "full" {
                let rectangle = ContourPixelGate.inspect(bitmap, hardware: hardware, fractions: [100, 100], transform: { _ in ContourPixel(r: 0, g: 0, b: 0, a: 1) })
                let noProgress = ContourPixelGate.inspect(bitmap, hardware: hardware, fractions: [100, 100], transform: { pixel in
                    ContourPixel(r: pixel.light, g: pixel.light, b: pixel.light, a: pixel.a)
                })
                passed = passed && !rectangle.valid && !noProgress.valid
                SmokeDiagnostics.mark("contour negative controls scale=\(scale) blackRectangleRejected=\(!rectangle.valid) missingProgressRejected=\(!noProgress.valid)")
            }
        }
        sceneIndex += 1
        if sceneIndex < scenes.count { setScene() }
        else {
            for scale in [1, 2] {
                guard let full = results["full"]?[scale], let quarter = results["quarter"]?[scale],
                      let fresh = results["eighty-three"]?[scale], let stale = results["stale"]?[scale],
                      let pending = results["reset-pending"]?[scale], let updated = results["updated-full"]?[scale],
                      let recollapsed = results["recollapsed"]?[scale] else { passed = false; continue }
                for side in 0...1 {
                    passed = passed && full.colors[side] > quarter.colors[side] * 1.5
                        && abs(full.colors[side] - updated.colors[side]) < 3
                        && abs(full.colors[side] - recollapsed.colors[side]) < 3
                }
                passed = passed && stale.brightness < fresh.brightness * 0.9 && pending.brightness < fresh.brightness * 0.9
            }
            finish(passed)
        }
    }
    private func finish(_ result: Bool) {
        stop()
        print(result ? "CONTOUR_OK: native transparent contour, quota arcs and live updates passed at 1x/2x offscreen" : "CONTOUR_FAILED: native contour pixel contract failed")
        completion(result)
    }
    func stop() {
        timer?.invalidate(); timer = nil
        legacyPanel?.close(); legacyPanel = nil
        island.stop()
    }
}
#endif
