#if os(macOS)
import AppKit
import SwiftUI
import QuartzCore
import NotchCore

/// One immutable input for the surface, outline and clipping path of a paint pass.
/// Geometry and all reveal curves are the v0.1.7 values; this changes their submission.
struct IslandVisualFrame {
    let progress: Double
    let viewport: CGSize
    let noticeID: UUID?
    let contour: IslandContour
    let surfaceOpacity: Double
    let railOpacity: Double
    init(geometry: IslandGeometry, progress: Double, viewport: CGSize, noticeID: UUID? = nil, baseline: Bool = false) {
        self.progress = progress; self.viewport = viewport; self.noticeID = noticeID
        contour = IslandContour(rect: geometry.contourRect(progress: progress), progress: progress,
            cornerAdjustment: geometry.shapeCalibration.corner, referenceDepth: geometry.notch.height)
        surfaceOpacity = baseline ? min(1, progress * 3) : IslandReveal.surface(progress)
        railOpacity = baseline ? max(0, 1 - progress * 4) : IslandReveal.rail(progress)
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
}

/// Drawing writes only this non-observable receipt. It never publishes state or queues
/// a view update. A lock also makes the diagnostic safe if SwiftUI chooses another thread.
final class IslandPaintStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: IslandPaintReceipt?
    func record(_ frame: IslandVisualFrame, actualViewport: CGSize, body: Path, rail: Path) {
        lock.lock(); defer { lock.unlock() }
        value = IslandPaintReceipt(sequence: (value?.sequence ?? 0) &+ 1, observed: CACurrentMediaTime(),
            frame: frame, actualViewport: actualViewport, bodyBounds: body.boundingRect, railBounds: rail.boundingRect)
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
/// The previous layer composition is retained only as a synthetic middle-frame
/// reference. It is never used in the normal application or timer path.
@MainActor
private struct PreviousPaintComposition: View {
    @ObservedObject var model: MeterModel
    let geometry: IslandGeometry
    let progress: Double
    var body: some View {
        let rect = geometry.contourRect(progress: progress)
        let shape = IslandSilhouette(progress: progress, drawingRect: rect,
            cornerAdjustment: geometry.shapeCalibration.corner, referenceDepth: geometry.notch.height)
        Color.clear.overlay { shape.fill(.black.opacity(IslandReveal.surface(progress))) }
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
    static func check(current: NativeContourBitmap, model: MeterModel, geometry: IslandGeometry, progress: Double) -> Bool {
        guard model.demo, CommandLine.arguments.contains("--collapse-test") else { return false }
        let frame = geometry.frame(progress: progress)
        let panel = TopEdgePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
        defer { panel.close() }
        let host = IslandHostingView(rootView: PreviousPaintComposition(model: model, geometry: geometry, progress: progress))
        host.sizingOptions = []; if #available(macOS 14.0, *) { host.safeAreaRegions = [] }
        panel.contentView = host; panel.setFrame(frame, display: true); panel.orderFrontRegardless()
        guard let reference = NativeContourBitmap.capture(host, scale: current.scale, topRowFirst: current.topRowFirst, padToWholePixels: true),
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
        SmokeDiagnostics.mark("paint composition parity theme=\(model.theme.rawValue) scale=\(current.scale) progress=\(progress) samples=\(count) premultipliedDifference=\(difference) valid=\(valid)")
        return valid
    }
}
#endif
