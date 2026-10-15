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
    var hueBin: Int? {
        let maximum = max(r, max(g, b)), minimum = min(r, min(g, b)), delta = maximum - minimum
        guard a > 0.8, delta > 0.25 else { return nil }
        let sector: Double
        if maximum == r { sector = (g - b) / delta }
        else if maximum == g { sector = 2 + (b - r) / delta }
        else { sector = 4 + (r - g) / delta }
        return Int(floor((sector + 6).truncatingRemainder(dividingBy: 6)))
    }
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
    let brightness: [Double]
    let hueBins: [Int]
    let signature: [Double]
    let failures: [String]
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
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { extent(proxy.size) }.onChange(of: proxy.size) { extent($0) }
                })
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
    }
}

@MainActor
private enum ContourPixelGate {
    /// Independent polyline sampling of the design contract, not the production SwiftUI Path.
    static func arcPoint(_ fraction: Double, size: CGSize) -> CGPoint {
        var points = [CGPoint(x: 2, y: 0), CGPoint(x: 2, y: size.height - 12)]
        for step in 1...100 {
            let t = CGFloat(step) / 100
            points.append(CGPoint(x: 2 + 10 * t * t, y: size.height - 12 + 20 * t - 10 * t * t))
        }
        points.append(CGPoint(x: size.width - 12, y: size.height - 2))
        for step in 1...100 {
            let t = CGFloat(step) / 100
            points.append(CGPoint(x: size.width - 12 + 20 * t - 10 * t * t, y: size.height - 2 - 10 * t * t))
        }
        points.append(CGPoint(x: size.width - 2, y: 0))
        let lengths = zip(points, points.dropFirst()).map { pair in hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y) }
        var distance = CGFloat(fraction) * lengths.reduce(0, +)
        for (index, length) in lengths.enumerated() {
            if distance <= length {
                let t = length > 0 ? distance / length : 0
                return CGPoint(x: points[index].x + (points[index + 1].x - points[index].x) * t,
                    y: points[index].y + (points[index + 1].y - points[index].y) * t)
            }
            distance -= length
        }
        return points.last!
    }
    static func inspect(_ bitmap: NativeContourBitmap, hardware: CGRect, percent: Double?,
                        transform: (ContourPixel) -> ContourPixel = { $0 }, reversed: Bool = false,
                        eraseCenter: Bool = false, graySuffix: Bool = false, opposedHalves: Bool = false) -> ContourMetrics {
        let size = bitmap.size
        let corners = [CGPoint(x: 0.5, y: size.height - 0.5), CGPoint(x: 2.5, y: size.height - 0.5),
                       CGPoint(x: 0.5, y: size.height - 2.5), CGPoint(x: size.width - 0.5, y: size.height - 0.5),
                       CGPoint(x: size.width - 2.5, y: size.height - 0.5)]
        let transparent = corners.allSatisfy { point in
            transform(bitmap.pixel(x: Int(point.x * CGFloat(bitmap.scale)), y: Int(point.y * CGFloat(bitmap.scale)))).a < 0.05
        }
        let interior = transform(bitmap.pixel(x: bitmap.representation.pixelsWide / 2, y: 8 * bitmap.scale)).a < 0.05
        var nonblackExterior = 0
        var colors = [0.0, 0.0], track = [0.0, 0.0], light = [0.0, 0.0], lightCount = [0.0, 0.0]
        for y in 0..<bitmap.representation.pixelsHigh {
            for x in 0..<bitmap.representation.pixelsWide {
                let px = CGFloat(x) / CGFloat(bitmap.scale), py = CGFloat(y) / CGFloat(bitmap.scale)
                guard !hardware.contains(CGPoint(x: px, y: py)) else { continue }
                let pixel = transform(bitmap.pixel(x: x, y: y)); let side = px < size.width / 2 ? 0 : 1
                if pixel.chromatic { colors[side] += 1 }
                if pixel.a > 0.01 && max(pixel.r, max(pixel.g, pixel.b)) > 0.01 { nonblackExterior += 1 }
                // Identical spatial population, including black and transparent pixels.
                light[side] += pixel.light * pixel.a; lightCount[side] += 1
                if pixel.a > 0.2 { track[side] += 1 }
            }
        }
        var hues = Set<Int>(), signature: [Double] = [], failures: [String] = []
        if !transparent { failures.append("opaque-corner") }; if !interior { failures.append("opaque-interior") }
        let fraction = (percent ?? 0) / 100
        // Dense full-U probes prove a left prefix, right consumed suffix and continuous center.
        let probes = stride(from: 0.025, through: 0.975, by: 0.025).map { $0 }
            + [fraction - 0.035, fraction + 0.035].filter { $0 > 0 && $0 < 1 }
        for location in probes where abs(location - fraction) > 0.02 {
            let point = arcPoint(reversed ? 1 - location : location, size: size)
            var pixels = bitmap.near(point, transform: transform)
            if eraseCenter && abs(location - 0.5) < 0.03 { pixels = [ContourPixel(r: 0, g: 0, b: 0, a: 0)] }
            if graySuffix && location > fraction { pixels = [ContourPixel(r: 0.3, g: 0.3, b: 0.3, a: 1)] }
            if opposedHalves {
                let oldColor = location < fraction / 2 || location > 1 - fraction / 2
                pixels = [oldColor ? ContourPixel(r: 0.4, g: 0.9, b: 0.7, a: 1) : ContourPixel(r: 0, g: 0, b: 0, a: 1)]
            }
            let colored = pixels.contains { $0.chromatic }
            let expectedColor = location < fraction
            if colored != expectedColor { failures.append("arc\(location)-colored\(colored)") }
            if !expectedColor && pixels.contains(where: { $0.a > 0.1 && max($0.r, max($0.g, $0.b)) > 0.035 }) {
                failures.append("consumed-not-black-\(location)")
            }
            if !pixels.contains(where: { $0.a > 0.85 }) { failures.append("discontinuous-track-\(location)") }
            for pixel in pixels { if let hue = pixel.hueBin { hues.insert(hue) } }
        }
        for location in [0.2, 0.4, 0.6] {
            let pixels = bitmap.near(arcPoint(location, size: size), transform: transform)
            let core = pixels.max { $0.light * $0.a < $1.light * $1.a } ?? ContourPixel(r: 0, g: 0, b: 0, a: 0)
            signature += [core.r * core.a, core.g * core.a, core.b * core.a]
        }
        let totalColor = colors.reduce(0, +) / Double(bitmap.scale * bitmap.scale)
        if fraction == 0 && (totalColor != 0 || nonblackExterior != 0) { failures.append("zero-or-unknown-not-pure-black-\(nonblackExterior)") }
        if fraction > 0 && totalColor < 15 { failures.append("missing-exterior-color") }
        if track.contains(where: { $0 <= 30 * Double(bitmap.scale * bitmap.scale) }) { failures.append("missing-black-outline") }
        return ContourMetrics(valid: failures.isEmpty, colors: colors.map { $0 / Double(bitmap.scale * bitmap.scale) },
            track: track.map { $0 / Double(bitmap.scale * bitmap.scale) },
            brightness: (0...1).map { lightCount[$0] > 0 ? light[$0] / lightCount[$0] : 0 },
            hueBins: [hues.count], signature: signature, failures: failures)
    }
}

/// Native rendering-state regression. All scenes update one live demo MeterModel.
@MainActor
final class ContourRenderHarness: NSObject {
    private struct Scene {
        let name: String, left: Double?, right: Double?
        var stale = false, pending = false, expanded = false
        var theme: MeterTheme? = nil
        var secondary = false
        var phase: Double = 0
    }
    private let scenes: [Scene] = [
        Scene(name: "full", left: 100, right: 38), Scene(name: "seventy-five", left: 75, right: 38),
        Scene(name: "half", left: 50, right: 38), Scene(name: "quarter", left: 25, right: 38),
        Scene(name: "zero", left: 0, right: 38), Scene(name: "unknown", left: nil, right: 38),
        Scene(name: "eighty-three", left: 83, right: 38), Scene(name: "stale", left: 83, right: 38, stale: true),
        Scene(name: "reset-pending", left: 83, right: 38, pending: true),
        Scene(name: "primary-quarter", left: 25, right: 75),
        Scene(name: "secondary-three-quarters", left: 25, right: 75, secondary: true),
        Scene(name: "primary-restored", left: 25, right: 75),
        Scene(name: "updated-full", left: 100, right: 38), Scene(name: "expanded", left: 83, right: 38, expanded: true),
        Scene(name: "recollapsed", left: 100, right: 38),
        Scene(name: "theme-standard", left: 100, right: 38, theme: .standard),
        Scene(name: "theme-rainbow", left: 100, right: 38, theme: .rainbow),
        Scene(name: "theme-aurora", left: 100, right: 38, theme: .aurora),
        Scene(name: "theme-sunset", left: 100, right: 38, theme: .sunset),
        Scene(name: "theme-ice", left: 100, right: 38, theme: .ice),
        Scene(name: "theme-restored", left: 100, right: 38),
        Scene(name: "phase-zero", left: 75, right: 38),
        Scene(name: "phase-quarter", left: 75, right: 38, phase: 0.25),
        Scene(name: "phase-half", left: 75, right: 38, phase: 0.5),
        Scene(name: "phase-three-quarters", left: 75, right: 38, phase: 0.75)
    ]
    private let model: MeterModel
    private let initialTheme: MeterTheme
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
        self.model = model; self.initialTheme = model.theme; self.island = island; self.completion = completion
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
        SmokeDiagnostics.mark("contour theme=\(model.theme.rawValue)")
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
        model.theme = scene.theme ?? initialTheme
        model.preferredQuota = scene.secondary ? "render-1" : ""
        model.setSkinPhaseForTesting(scene.phase)
        model.setContourFixture(left: scene.left, right: scene.right, stale: scene.stale, pending: scene.pending)
        island.setContourTestProgress(scene.expanded ? 1 : 0)
    }
    @objc private func captureScene(_ timer: Timer) {
        let scene = scenes[sceneIndex]
        let phaseValid = abs(model.skinPhase - scene.phase) < 0.000001
        passed = passed && phaseValid
        SmokeDiagnostics.mark("contour actual phase scene=\(scene.name) expected=\(scene.phase) actual=\(model.skinPhase) valid=\(phaseValid)")
        guard let view = island.panel.contentView else { finish(false); return }
        if sceneIndex == 0, let legacy = legacyPanel?.contentView {
            legacy.layoutSubtreeIfNeeded(); legacy.displayIfNeeded()
            SmokeDiagnostics.mark("legacy layout fixture host=\(legacy.bounds.size) silhouette=\(legacyExtent) opaque=\(legacy.isOpaque)")
            for scale in [1, 2] {
                if let bitmap = NativeContourBitmap.capture(legacy, scale: scale, topRowFirst: orientations[scale] ?? true) {
                    do { try bitmap.export(name: "legacy-layout-control", hardware: CGSize(width: 220, height: 32)) } catch { passed = false }
                    let metrics = ContourPixelGate.inspect(bitmap, hardware: CGRect(x: 6, y: 0, width: 220, height: 32), percent: 100)
                    SmokeDiagnostics.mark("legacy layout fixture scale=\(scale) measuredSilhouette=\(legacyExtent) extentAvailable=\(legacyExtent.width > 0 && legacyExtent.height > 0) colorArea=\(metrics.colors) contourContract=\(metrics.valid)")
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
            let metrics = ContourPixelGate.inspect(bitmap, hardware: hardware, percent: scene.secondary ? scene.right : scene.left)
            results[scene.name, default: [:]][scale] = metrics
            passed = passed && metrics.valid
            SmokeDiagnostics.mark("contour pixels scene=\(scene.name) scale=\(scale) colorArea=\(metrics.colors) trackArea=\(metrics.track) brightness=\(metrics.brightness) hueBins=\(metrics.hueBins) valid=\(metrics.valid) failures=\(metrics.failures)")
            if scene.name == "full" || scene.name.hasPrefix("theme-") {
                let themeVisible = metrics.hueBins.allSatisfy { model.theme == .rainbow ? $0 >= 5 : $0 >= 1 && $0 <= 4 }
                passed = passed && themeVisible
                SmokeDiagnostics.mark("contour theme coverage scene=\(scene.name) theme=\(model.theme.rawValue) scale=\(scale) hueBins=\(metrics.hueBins) valid=\(themeVisible)")
            }
            if scene.name == "quarter" {
                let reverse = ContourPixelGate.inspect(bitmap, hardware: hardware, percent: 25, reversed: true)
                let gray = ContourPixelGate.inspect(bitmap, hardware: hardware, percent: 25, graySuffix: true)
                let opposed = ContourPixelGate.inspect(bitmap, hardware: hardware, percent: 25, opposedHalves: true)
                passed = passed && !reverse.valid && !gray.valid && !opposed.valid
                SmokeDiagnostics.mark("contour direction controls scale=\(scale) reversedFillRejected=\(!reverse.valid) graySuffixRejected=\(!gray.valid) opposedHalvesRejected=\(!opposed.valid)")
            }
            if scene.name == "full" {
                let rectangle = ContourPixelGate.inspect(bitmap, hardware: hardware, percent: 100, transform: { _ in ContourPixel(r: 0, g: 0, b: 0, a: 1) })
                let noProgress = ContourPixelGate.inspect(bitmap, hardware: hardware, percent: 100, transform: { pixel in
                    ContourPixel(r: pixel.light, g: pixel.light, b: pixel.light, a: pixel.a)
                })
                let gap = ContourPixelGate.inspect(bitmap, hardware: hardware, percent: 100, eraseCenter: true)
                passed = passed && !rectangle.valid && !noProgress.valid && !gap.valid
                SmokeDiagnostics.mark("contour negative controls scale=\(scale) blackRectangleRejected=\(!rectangle.valid) missingProgressRejected=\(!noProgress.valid) centerGapRejected=\(!gap.valid)")
            }
        }
        sceneIndex += 1
        if sceneIndex < scenes.count { setScene() }
        else {
            for scale in [1, 2] {
                guard let full = results["full"]?[scale], let quarter = results["quarter"]?[scale],
                      let fresh = results["eighty-three"]?[scale], let stale = results["stale"]?[scale],
                      let pending = results["reset-pending"]?[scale], let updated = results["updated-full"]?[scale],
                      let recollapsed = results["recollapsed"]?[scale], let restored = results["theme-restored"]?[scale] else { passed = false; continue }
                let area = { (value: ContourMetrics) in value.colors.reduce(0, +) }
                let restoredValid = area(full) > area(quarter) * 2
                    && abs(area(full) - area(updated)) < 3 && abs(area(full) - area(recollapsed)) < 3
                    && abs(area(full) - area(restored)) < 3 && full.hueBins == restored.hueBins
                    && zip(full.signature, restored.signature).allSatisfy { pair in abs(pair.0 - pair.1) < 0.01 }
                passed = passed && restoredValid
                SmokeDiagnostics.mark("contour restore scale=\(scale) valid=\(restoredValid)")
                let themes = MeterTheme.allCases
                for first in themes.indices {
                    for second in themes.indices where second > first {
                        guard let a = results["theme-" + themes[first].rawValue]?[scale],
                              let b = results["theme-" + themes[second].rawValue]?[scale] else { passed = false; continue }
                        let difference = zip(a.signature, b.signature).map { pair in abs(pair.0 - pair.1) }.reduce(0, +)
                        let distinct = difference > 0.15
                        passed = passed && distinct
                        SmokeDiagnostics.mark("contour live palettes scale=\(scale) pair=\(themes[first].rawValue)/\(themes[second].rawValue) delta=\(difference) distinct=\(distinct)")
                    }
                }
                if let phase0 = results["phase-zero"]?[scale] {
                    for name in ["phase-quarter", "phase-half", "phase-three-quarters"] {
                        guard let other = results[name]?[scale] else { passed = false; continue }
                        let delta = zip(phase0.signature, other.signature).map { pair in abs(pair.0 - pair.1) }.reduce(0, +)
                        let valid = initialTheme == .rainbow ? delta > 0.3 : delta < 0.01
                        passed = passed && valid
                        SmokeDiagnostics.mark("contour phase scale=\(scale) scene=\(name) theme=\(initialTheme.rawValue) delta=\(delta) endpointsValid=\(other.valid) valid=\(valid)")
                    }
                } else { passed = false }
                for side in 0...1 {
                    let dimming = stale.brightness[side] < fresh.brightness[side] * 0.9
                        && pending.brightness[side] < fresh.brightness[side] * 0.9
                    let unchangedWouldFail = !(fresh.brightness[side] < fresh.brightness[side] * 0.9)
                    passed = passed && dimming && unchangedWouldFail
                    SmokeDiagnostics.mark("contour fixed-mask dimming scale=\(scale) rail=\(side) fresh=\(fresh.brightness[side]) stale=\(stale.brightness[side]) pending=\(pending.brightness[side]) valid=\(dimming) unchangedControlRejected=\(unchangedWouldFail)")
                }
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
