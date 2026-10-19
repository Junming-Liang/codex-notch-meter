#if os(macOS)
import AppKit
import SwiftUI
import QuartzCore
import NotchCore

/// One immutable input for the surface, outline and clipping path of a paint pass.
/// Body and rail share geometry and one synchronous submission; only the body
/// reveal follows its remaining distance to idle, keeping the shrinking shell visible.
struct IslandVisualFrame {
    let progress: Double
    let frameRevision: UInt64
    let viewport: CGSize
    let noticeID: UUID?
    let musicRevision: UInt64
    let contour: IslandContour
    let accessoryProgress: Double
    let surfaceOpacity: Double
    let railOpacity: Double
    init(geometry: IslandGeometry, progress: Double, viewport: CGSize, frameRevision: UInt64 = 0, noticeID: UUID? = nil, musicRevision: UInt64 = 0, baseline: Bool = false, musicPerimeter: Bool = false) {
        self.progress = progress; self.frameRevision = frameRevision; self.viewport = viewport; self.noticeID = noticeID; self.musicRevision = musicRevision
        contour = IslandContour(rect: geometry.contourRect(progress: progress), progress: progress,
            cornerAdjustment: geometry.shapeCalibration.corner, referenceDepth: geometry.notch.height)
        let accessory = geometry.showsMusicAccessories ? geometry.musicAccessoryProgress : 0
        accessoryProgress = accessory
        surfaceOpacity = max(accessory, baseline ? min(1, progress * 3) : geometry.surfaceOpacity(progress: progress))
        railOpacity = musicPerimeter ? 1 : max(accessory, baseline ? max(0, 1 - progress * 4) : IslandReveal.rail(progress))
    }
    var bodyPath: Path { contourPath(contour, inset: 0, closed: true) }
    var railPath: Path { contourPath(contour, inset: 2, closed: false) }
}

struct IslandPaintReceipt {
    let sequence: UInt64
    let observed: TimeInterval
    let frame: IslandVisualFrame
    let actualViewport: CGSize
    let bodyBounds: CGRect
    let railBounds: CGRect
    let nativeFrame: CGRect
    let nativeContentBounds: CGRect
    let nativeFrameSampledAtPaint: Bool
}

/// Drawing writes only this non-observable receipt. It never publishes state or queues
/// a view update. A lock also makes the diagnostic safe if SwiftUI chooses another thread.
final class IslandPaintStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: IslandPaintReceipt?
    private var records: [IslandPaintReceipt] = []
    private var overflow = false
    private var nativeGeometryProvider: (@MainActor () -> (CGRect, CGRect))?
    @MainActor func setNativeGeometryProvider(_ provider: @escaping @MainActor () -> (CGRect, CGRect)) {
        lock.lock(); defer { lock.unlock() }; nativeGeometryProvider = provider
    }
    private var nativeFrame: CGRect = .zero
    private var nativeContentBounds: CGRect = .zero
    func recordNativeFrame(_ frame: CGRect, contentBounds: CGRect) {
        lock.lock(); defer { lock.unlock() }
        nativeFrame = frame; nativeContentBounds = contentBounds
    }
    var historyOverflow: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    private let collectsHistory = CommandLine.arguments.contains("--music-test")
    func record(_ frame: IslandVisualFrame, actualViewport: CGSize, body: Path, rail: Path) {
        lock.lock()
        let provider = nativeGeometryProvider
        lock.unlock()
        let actual: (CGRect, CGRect)?
        if Thread.isMainThread, let provider {
            actual = MainActor.assumeIsolated { provider() }
        } else { actual = nil }
        lock.lock(); defer { lock.unlock() }
        if let actual { nativeFrame = actual.0; nativeContentBounds = actual.1 }
        value = IslandPaintReceipt(sequence: (value?.sequence ?? 0) &+ 1, observed: CACurrentMediaTime(),
            frame: frame, actualViewport: actualViewport, bodyBounds: body.boundingRect, railBounds: rail.boundingRect,
            nativeFrame: nativeFrame, nativeContentBounds: nativeContentBounds, nativeFrameSampledAtPaint: actual != nil)
        if collectsHistory, let value {
            if records.count >= 4096 { overflow = true; records.removeFirst(2048) }
            records.append(value)
        }
    }
    func history() -> [IslandPaintReceipt] {
        lock.lock(); defer { lock.unlock() }; return records
    }
    func latest() -> IslandPaintReceipt? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

struct IslandPaintView: View {
    let frame: IslandVisualFrame
    let remaining: Double?
    let theme: MeterTheme
    let colorPhase: Double
    let dimmed: Bool
    let store: IslandPaintStore
    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
            let body = frame.bodyPath, rail = frame.railPath
            var surface = context
            surface.opacity = frame.surfaceOpacity
            surface.fill(body, with: .color(.black))
            var outline = context
            outline.opacity = frame.railOpacity
            // The old ZStack had one group-opacity operation. Preserve that grouping:
            // fading black and color separately would increase alpha at their overlap.
            outline.drawLayer { layer in
                layer.stroke(rail, with: .color(.black), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                if let remaining, remaining > 0 {
                    layer.opacity = dimmed ? 0.55 : 1
                    let paint = quotaPaint(remaining, theme: theme, phase: colorPhase)
                        .in(CGRect(origin: .zero, size: frame.viewport))
                    layer.stroke(rail.trimmedPath(from: 0, to: CGFloat(remaining / 100)),
                        with: .style(paint), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                }
            }
            // The receipt describes the actual synchronous callback, not compositor scanout.
            store.record(frame, actualViewport: size, body: body, rail: rail)
        }
    }
}
/// The prior layer composition is a synthetic parity reference using the current
/// opacity. legacySurface separately recreates the old early fade as a negative control.
/// Neither path is used in the normal application or timer driver.
@MainActor
private struct ReferencePaintComposition: View {
    @ObservedObject var model: MeterModel
    let geometry: IslandGeometry
    let progress: Double
    let legacySurface: Bool
    var body: some View {
        let rect = geometry.contourRect(progress: progress)
        let shape = IslandSilhouette(progress: progress, drawingRect: rect,
            cornerAdjustment: geometry.shapeCalibration.corner, referenceDepth: geometry.notch.height)
        Color.clear.overlay { shape.fill(.black.opacity(legacySurface ? IslandReveal.smooth(progress * 3) : geometry.surfaceOpacity(progress: progress))) }
            .overlay {
                RailView(model: model, drawingRect: rect, progress: progress,
                    cornerAdjustment: geometry.shapeCalibration.corner, referenceDepth: geometry.notch.height,
                    hovered: { _ in }).opacity(IslandReveal.rail(progress))
            }
            .frame(width: geometry.frame(progress: progress).width, height: geometry.frame(progress: progress).height)
            .clipShape(shape).ignoresSafeArea(.all).transaction { $0.animation = nil }
    }
}

@MainActor
enum IslandPaintParity {
    static func captureReference(model: MeterModel, geometry: IslandGeometry, progress: Double,
                                 scale: Int, topRowFirst: Bool, legacySurface: Bool) -> NativeContourBitmap? {
        guard model.demo, CommandLine.arguments.contains("--collapse-test") else { return nil }
        let frame = geometry.frame(progress: progress)
        let panel = TopEdgePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
        defer { panel.close() }
        let host = IslandHostingView(rootView: ReferencePaintComposition(model: model, geometry: geometry,
            progress: progress, legacySurface: legacySurface))
        host.sizingOptions = []; if #available(macOS 14.0, *) { host.safeAreaRegions = [] }
        panel.contentView = host; panel.setFrame(frame, display: true); panel.orderFrontRegardless()
        let bitmap = NativeContourBitmap.capture(host, scale: scale, topRowFirst: topRowFirst, padToWholePixels: true)
        if legacySurface, progress == 0.02 {
            SmokeDiagnostics.mark("paint legacy-reference-layout theme=\(model.theme.rawValue) scale=\(scale) progress=\(progress) intendedFrame=\(frame) panelFrame=\(panel.frame) hostFrame=\(host.frame) hostBounds=\(host.bounds) viewport=\(String(describing: bitmap?.size)) pixelsWide=\(bitmap?.representation.pixelsWide ?? 0) pixelsHigh=\(bitmap?.representation.pixelsHigh ?? 0) topRowFirst=\(topRowFirst) panelBacking=\(panel.backingScaleFactor) diagnosticOnly=true scanout=false")
        }
        return bitmap
    }
    static func check(current: NativeContourBitmap, model: MeterModel, geometry: IslandGeometry, progress: Double) -> Bool {
        guard let reference = captureReference(model: model, geometry: geometry, progress: progress,
            scale: current.scale, topRowFirst: current.topRowFirst, legacySurface: false),
              reference.size == current.size else { return false }
        let rect = geometry.contourRect(progress: progress)
        let side = rect.minX + CGFloat(12 * progress), depth = rect.height / 2
        var total = 0.0, count = 0, energy = 0.0
        for y in 0..<current.representation.pixelsHigh {
            let yy = (CGFloat(y) + 0.5) / CGFloat(current.scale)
            guard abs(yy - depth) <= 4 else { continue }
            for x in 0..<current.representation.pixelsWide {
                let xx = (CGFloat(x) + 0.5) / CGFloat(current.scale)
                // Independent side band includes outside AA, black backing and color.
                guard xx >= side - 2, xx <= side + 6 else { continue }
                let a = current.pixel(x: x, y: y), b = reference.pixel(x: x, y: y)
                total += abs(a.a - b.a) + abs(a.r * a.a - b.r * b.a)
                    + abs(a.g * a.a - b.g * b.a) + abs(a.b * a.a - b.b * b.a)
                energy += b.a; count += 4
            }
        }
        let difference = count > 0 ? total / Double(count) : Double.infinity
        let valid = count >= 100 && energy > 8 && difference < 0.035
        SmokeDiagnostics.mark("paint composition parity current-surface theme=\(model.theme.rawValue) scale=\(current.scale) progress=\(progress) samples=\(count) premultipliedDifference=\(difference) valid=\(valid)")
        return valid
    }
}
#endif
