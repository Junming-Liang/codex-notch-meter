#if os(macOS)
import AppKit
import SwiftUI
import NotchCore

/// v0.1.6 paint only, on the unchanged current path/clip. Synthetic comparison, never normal UI.
@MainActor
private struct PreviousStrokeFixture: View {
    @ObservedObject var model: MeterModel
    let geometry: IslandGeometry
    var body: some View {
        let rect = geometry.contourRect(progress: 0)
        let remaining = model.primaryWindow?.remainingPercent
        ZStack {
            NotchRail(drawingRect: rect, referenceDepth: geometry.notch.height)
                .stroke(.black, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            if let remaining, remaining > 0 {
                NotchRail(drawingRect: rect, referenceDepth: geometry.notch.height).trim(from: 0, to: remaining / 100)
                    .stroke(quotaPaint(remaining, theme: model.theme, phase: model.skinPhase),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
        .frame(width: geometry.frame(progress: 0).width, height: geometry.frame(progress: 0).height)
        .clipShape(IslandSilhouette(progress: 0, drawingRect: rect, referenceDepth: geometry.notch.height))
        .ignoresSafeArea(.all).transaction { $0.animation = nil }
    }
}

/// Native paired normal-to-circle samples. No desktop capture, physical-mask inference or account.
@MainActor
final class StrokeCoverageHarness {
    private let panel: TopEdgePanel
    private let model: MeterModel
    init(model: MeterModel, geometry: IslandGeometry) {
        self.model = model
        let frame = geometry.frame(progress: 0)
        panel = TopEdgePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        let host = IslandHostingView(rootView: PreviousStrokeFixture(model: model, geometry: geometry))
        host.sizingOptions = []; if #available(macOS 14.0, *) { host.safeAreaRegions = [] }
        panel.contentView = host; panel.setFrame(frame, display: true); panel.orderFrontRegardless()
    }
    func stop() { panel.close() }

    private struct Coverage {
        let alpha: Double, chroma: Double, white: Double, dark: Double
        var backgroundLeak: Double { (white - dark) / 0.88 }
    }
    /// Bilinear samples use actual pixel centers; the bitmap is never resized or reinterpreted.
    private func sample(_ bitmap: NativeContourBitmap, _ point: CGPoint) -> ContourPixel {
        let x = Double(point.x) * Double(bitmap.scale) - 0.5
        let y = Double(point.y) * Double(bitmap.scale) - 0.5
        let x0 = Int(floor(x)), y0 = Int(floor(y)), tx = x - floor(x), ty = y - floor(y)
        var a = 0.0, r = 0.0, g = 0.0, b = 0.0
        for (dx, wx) in [(0, 1 - tx), (1, tx)] { for (dy, wy) in [(0, 1 - ty), (1, ty)] {
            guard x0 + dx >= 0, y0 + dy >= 0,
                  x0 + dx < bitmap.representation.pixelsWide, y0 + dy < bitmap.representation.pixelsHigh else { continue }
            let pixel = bitmap.pixel(x: x0 + dx, y: y0 + dy), weight = wx * wy
            a += pixel.a * weight; r += pixel.r * pixel.a * weight
            g += pixel.g * pixel.a * weight; b += pixel.b * pixel.a * weight
        }}
        return ContourPixel(r: a > 0 ? r / a : 0, g: a > 0 ? g / a : 0, b: a > 0 ? b / a : 0, a: a)
    }
    private func coverage(_ bitmap: NativeContourBitmap, points: [CGPoint]) -> Coverage {
        var alpha = 0.0, chroma = 0.0, white = 0.0, dark = 0.0
        for point in points {
            let pixel = sample(bitmap, point)
            alpha += pixel.a
            chroma += (max(pixel.r, max(pixel.g, pixel.b)) - min(pixel.r, min(pixel.g, pixel.b))) * pixel.a
            white += pixel.light * pixel.a + 0.96 * (1 - pixel.a)
            dark += pixel.light * pixel.a + 0.08 * (1 - pixel.a)
        }
        let count = Double(points.count)
        return Coverage(alpha: alpha / count, chroma: chroma / count, white: white / count, dark: dark / count)
    }
    func inspect(current: NativeContourBitmap, hardware: CGRect, scene: String, percent: Double?) -> Bool {
        guard model.demo, let view = panel.contentView,
              let previous = NativeContourBitmap.capture(view, scale: current.scale, topRowFirst: current.topRowFirst),
              previous.size == current.size else { return false }
        // Raw input determines both corner centers; it does not call production contour commands.
        let lower: CGFloat = min(8 * min(2, max(0.5, hardware.height / 32)) + 3, (hardware.height + 3) / 2) - 2
        let bottom = hardware.maxY + 1
        var valid = true
        for left in [true, false] {
            let center = CGPoint(x: left ? hardware.minX - 1 + lower : hardware.maxX + 1 - lower, y: bottom - lower)
            func points(_ offsets: [Double]) -> [CGPoint] {
                offsets.flatMap { offset in (0...12).map { step in
                    let degrees: Double = left ? 105 + Double(step) * 5 : 15 + Double(step) * 5
                    let angle: Double = degrees * Double.pi / 180
                    let cosine: Double = cos(angle), sine: Double = sin(angle)
                    let radius = lower + CGFloat(offset)
                    return CGPoint(x: center.x + radius * CGFloat(cosine), y: center.y + radius * CGFloat(sine))
                }}
            }
            // Inner normal bands cross the old paint edge and the new additional coverage.
            let blackBand = points([-2, -1.75, -1.5])
            let colorBand = points([-1.5, -1.25, -1])
            let oldBlack = coverage(previous, points: blackBand), newBlack = coverage(current, points: blackBand)
            let oldColor = coverage(previous, points: colorBand), newColor = coverage(current, points: colorBand)
            let shouldColor = (percent ?? 0) >= 100 || (left && (percent ?? 0) >= 25)
            let corePoints = points([-0.5, 0, 0.5])
            let core = corePoints.map { sample(current, $0) }
            let oldCore = corePoints.map { sample(previous, $0) }
            func coreValid(_ values: [ContourPixel]) -> Bool {
                !values.isEmpty && values.allSatisfy { pixel in
                    let difference = max(pixel.r, max(pixel.g, pixel.b)) - min(pixel.r, min(pixel.g, pixel.b))
                    return pixel.a > 0.9 && (shouldColor ? difference > 0.04 : max(pixel.r, max(pixel.g, pixel.b)) < 0.015)
                }
            }
            func accepts(_ black: Coverage, _ color: Coverage, _ values: [ContourPixel]) -> Bool {
                black.alpha > oldBlack.alpha + 0.025
                    && black.backgroundLeak < oldBlack.backgroundLeak - 0.025
                    && (shouldColor ? color.chroma > oldColor.chroma + 0.015 : color.chroma < 0.005)
                    && coreValid(values)
            }
            let referenceValid = coreValid(oldCore)
            let oldControlRejected = !accepts(oldBlack, oldColor, oldCore)
            let passed = referenceValid && accepts(newBlack, newColor, core) && oldControlRejected
            valid = valid && passed
            SmokeDiagnostics.mark("stroke coverage scene=\(scene) theme=\(model.theme.rawValue) scale=\(current.scale) side=\(left ? "left" : "right") alphaOld=\(oldBlack.alpha) alphaNew=\(newBlack.alpha) chromaOld=\(oldColor.chroma) chromaNew=\(newColor.chroma) whiteOld=\(oldBlack.white) whiteNew=\(newBlack.white) darkOld=\(oldBlack.dark) darkNew=\(newBlack.dark) backgroundLeakOld=\(oldBlack.backgroundLeak) backgroundLeakNew=\(newBlack.backgroundLeak) coreValid=\(coreValid(core)) referenceValid=\(referenceValid) oldWidthRejected=\(oldControlRejected) valid=\(passed)")
        }
        do { try previous.export(name: "stroke-previous-" + scene, hardware: hardware.size) } catch { valid = false }
        return valid
    }
}
#endif
