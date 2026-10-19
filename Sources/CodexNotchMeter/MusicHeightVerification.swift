#if os(macOS)
import AppKit
import QuartzCore
import NotchCore

/// Real own-view paint/bitmap evidence with a conservative rectangular cutout.
/// This does not capture the desktop or verify a user's physical notch/scanout.
@MainActor
@discardableResult
func verifyMusicClosedHeightAndMask(panel: IslandPanelController, model: MeterModel) async throws -> Bool {
    try MusicClosedHeightCheck.require(model.demo && CommandLine.arguments.contains("--music-test"),
        "closed-height verification is restricted to the synthetic Music harness")
    try MusicClosedHeightCheck.require(model.music.isFreshPlaying && !model.music.lyricsModeEnabled
        && panel.smokeProgress == 0 && panel.smokeTargetProgress == 0 && !panel.smokeMotionRunning
        && panel.smokeExpansionOwner == .idle && panel.geometry.showsMusicAccessories
        && panel.geometry.musicAccessoryProgress == 1,
        "closed-height input must be fresh playing, lyrics off and fully settled at the widened idle endpoint")
    let originalTheme = model.theme
    var normalGeometry = panel.geometry
    normalGeometry.showsMusicAccessories = false
    normalGeometry.musicAccessoryProgress = 0
    let normal = IslandPanelController(model: model, geometry: normalGeometry, startPolling: false,
        musicPresentationAllowed: false, hovered: {}, refresh: {}, settings: {}, quit: {})
    normal.panel.appearance = panel.panel.appearance
    defer { normal.stop(); model.theme = originalTheme; panel.panel.orderFrontRegardless() }
    let nativeScale = panel.panel.backingScaleFactor
    let scale = Int(nativeScale.rounded())
    try MusicClosedHeightCheck.require([1, 2].contains(scale) && abs(nativeScale - CGFloat(scale)) < 0.001
        && normal.panel.backingScaleFactor == nativeScale && panel.geometry.backingScale == nativeScale,
        "both real windows must use the declared 1x or 2x backing scale")
    let topRowFirst = try MusicClosedHeightCheck.orientation(scale: scale)
    var worstDifference = 0.0
    var minimumVisible = Double.infinity
    // Every iteration changes the value, including the first; an unchanged theme
    // need not invalidate an already cached Canvas display list.
    let themes = MeterTheme.allCases.filter { $0 != originalTheme } + [originalTheme]
    for theme in themes {
        let changedAt = CACurrentMediaTime()
        let normalSequence = normal.paintReceipt?.sequence ?? 0
        let musicSequence = panel.paintReceipt?.sequence ?? 0
        model.theme = theme
        let baseline = try await MusicClosedHeightCheck.capture(normal, scale: scale, topRowFirst: topRowFirst,
            after: changedAt, previousSequence: normalSequence)
        let playing = try await MusicClosedHeightCheck.capture(panel, scale: scale, topRowFirst: topRowFirst,
            after: changedAt, previousSequence: musicSequence)
        try MusicClosedHeightCheck.require(model.music.isFreshPlaying && !model.music.lyricsModeEnabled,
            "height comparison cannot outlive the fresh closed-playback fixture")
        try MusicClosedHeightCheck.compareGeometry(normal: normal, music: panel)
        let coverage = try MusicClosedHeightCheck.compareMaskedBottom(normal: baseline, music: playing,
            normalPanel: normal, musicPanel: panel)
        worstDifference = max(worstDifference, coverage.difference)
        minimumVisible = min(minimumVisible, coverage.visible)
        if theme == .standard {
            try MusicClosedHeightCheck.export(baseline, panel: normal, commonFrame: panel.panel.frame,
                name: "perimeter-closed-height-normal-raw-mask.png")
            try MusicClosedHeightCheck.export(playing, panel: panel, commonFrame: panel.panel.frame,
                name: "perimeter-closed-height-music-raw-mask.png")
        }
    }
    print("MUSIC_CLOSED_HEIGHT_MASK_OK: skins=5 sameHeight=true sameBottom=true widthOnly=true owner=idle rawMaskParity=true maxAlphaDifference=\(worstDifference) visibleBottomPoints=\(minimumVisible) actualBacking=\(scale) ownViewPixels=true physicalMaskVerified=false scanout=false")
    return true
}

/// The caller triggers a real fixture playback edge and awaits settled natural
/// paint. This checks every recorded in-flight closed frame, never synthetic p0
/// endpoints alone. Revision pairing is verified by the separate ingress gate.
@MainActor
@discardableResult
func verifyMusicClosedTransitionHeight(panel: IslandPanelController, model: MeterModel,
    after began: TimeInterval, transition: String) throws -> Bool {
    try MusicClosedHeightCheck.require(model.demo && CommandLine.arguments.contains("--music-test")
        && ["playback-start", "pause", "reconnect"].contains(transition)
        && began.isFinite && began <= CACurrentMediaTime(),
        "closed transition verification needs a bounded synthetic playback edge")
    let opening = transition != "pause", endpoint = opening ? 1.0 : 0.0
    try MusicClosedHeightCheck.require(!panel.smokeHistoryOverflow && !panel.smokePaintHistoryOverflow
        && !model.music.lyricsModeEnabled && MusicClosedHeightCheck.isClosed(panel)
        && model.music.isFreshPlaying == opening && panel.geometry.musicAccessoryProgress == endpoint,
        "playback edge must settle closed at its correct accessory endpoint without losing evidence")
    var normal = panel.geometry
    normal.showsMusicAccessories = false; normal.musicAccessoryProgress = 0
    let expected = normal.frame(progress: 0)
    let normalContour = IslandContour(rect: normal.contourRect(progress: 0),
        cornerAdjustment: normal.shapeCalibration.corner, referenceDepth: normal.notch.height)
    let normalBody = contourPath(normalContour, inset: 0, closed: true).boundingRect
    let normalRail = contourPath(normalContour, inset: 2, closed: false).boundingRect
    let commits = panel.smokeRenderCommits.filter { $0.observed >= began }
    let paints = panel.smokePaintHistory.filter { $0.observed >= began }
    let movingCommits = commits.filter { $0.geometry.musicAccessoryProgress > 0 && $0.geometry.musicAccessoryProgress < 1 }
    let movingPaints = paints.filter { $0.frame.accessoryProgress > 0 && $0.frame.accessoryProgress < 1 }
    try MusicClosedHeightCheck.require(movingCommits.count >= 3
        && Set(movingPaints.map { $0.frame.frameRevision }).count >= 2,
        "each playback edge needs multiple real intermediate width commits and native paints")
    for commit in commits {
        let frame = commit.nativeFrame, geometry = commit.geometry
        try MusicClosedHeightCheck.require(commit.progress == 0 && commit.target == 0 && commit.owner == .idle
            && geometry.hasSameAnchor(as: normal) && geometry.contourFrame == normal.contourFrame
            && frame.height == expected.height && frame.minY == expected.minY && frame.maxY == expected.maxY
            && frame == geometry.frame(progress: 0),
            "\(transition) cannot lift the native bottom or change closed height during accessory motion")
    }
    for paint in paints {
        try MusicClosedHeightCheck.require(paint.frame.progress == 0
            && paint.frame.viewport.height == expected.height && paint.actualViewport.height == expected.height
            && paint.frame.contour.rect.height == normalContour.rect.height
            && paint.bodyBounds.minY == normalBody.minY && paint.bodyBounds.maxY == normalBody.maxY
            && paint.railBounds.minY == normalRail.minY && paint.railBounds.maxY == normalRail.maxY,
            "\(transition) cannot lift the painted body/rail bottom even on an intermediate accessory frame")
    }
    for (a, b) in zip(commits, commits.dropFirst()) {
        let delta = b.geometry.musicAccessoryProgress - a.geometry.musicAccessoryProgress
        try MusicClosedHeightCheck.require(opening ? delta >= 0 : delta <= 0,
            "\(transition) accessory width must advance toward its endpoint without an unrequested reversal")
    }
    try MusicClosedHeightCheck.require(commits.last?.geometry.musicAccessoryProgress == endpoint
        && paints.last?.frame.accessoryProgress == endpoint,
        "\(transition) evidence must include the actual final commit and final paint")
    print("MUSIC_CLOSED_TRANSITION_HEIGHT_OK: transition=\(transition) commits=\(commits.count) movingCommits=\(movingCommits.count) paints=\(paints.count) movingPaints=\(Set(movingPaints.map { $0.frame.frameRevision }).count) sameHeight=true sameBottom=true widthOnly=true scanout=false")
    return true
}

@MainActor
private enum MusicClosedHeightCheck {
    static func require(_ valid: Bool, _ message: String) throws {
        if !valid { throw NSError(domain: "MusicClosedHeightVerification", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func orientation(scale: Int) throws -> Bool {
        let view = ScaleCalibrationView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let bitmap = NativeContourBitmap.capture(view, scale: scale, topRowFirst: true) else {
            throw NSError(domain: "MusicClosedHeightVerification", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot calibrate own-view bitmap orientation"])
        }
        let a = bitmap.pixel(x: 2 * scale, y: scale), b = bitmap.pixel(x: 2 * scale, y: 6 * scale)
        try require(((a.r > 0.9 && b.b > 0.9) || (a.b > 0.9 && b.r > 0.9))
            && abs(view.drawingScale.width - CGFloat(scale)) < 0.01
            && abs(view.drawingScale.height - CGFloat(scale)) < 0.01,
            "bitmap orientation and backing transform must be measured, never assumed")
        return a.r > 0.9
    }

    static func isClosed(_ panel: IslandPanelController) -> Bool {
        let expected = panel.geometry.frame(progress: 0), probe = panel.motionProbe
        return panel.smokeProgress == 0 && panel.smokeTargetProgress == 0 && panel.smokeVelocity == 0
            && !panel.smokeMotionRunning && !panel.isInteracting && panel.smokeExpansionOwner == .idle
            && !panel.smokeNoticeVisible && !panel.smokeNoticeTargetActive
            && panel.panel.ignoresMouseEvents && panel.placementIsValid && probe.visible && probe.nonKey
            && probe.frame == expected && probe.contentBounds == CGRect(origin: .zero, size: expected.size)
            && probe.renderedProgress == 0 && probe.viewport == expected.size
    }

    static func capture(_ panel: IslandPanelController, scale: Int, topRowFirst: Bool,
        after changedAt: TimeInterval, previousSequence: UInt64) async throws -> NativeContourBitmap {
        let began = CACurrentMediaTime()
        // Bring each transparent overlapping test window forward in turn. A normal
        // scheduled redraw must acknowledge the new theme before bitmap capture.
        panel.panel.orderFrontRegardless()
        panel.panel.contentView?.needsDisplay = true
        var ready = false
        while CACurrentMediaTime() - began < 2 {
            if let paint = panel.paintReceipt, paint.sequence > previousSequence, paint.observed >= changedAt,
               paint.frame.progress == 0, paint.frame.viewport == panel.panel.frame.size,
               paint.actualViewport == panel.panel.frame.size, isClosed(panel) {
                ready = true; break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(ready, "closed window must receive fresh natural paint before own-view bitmap capture")
        guard let view = panel.panel.contentView,
              let bitmap = NativeContourBitmap.capture(view, scale: scale, topRowFirst: topRowFirst) else {
            throw NSError(domain: "MusicClosedHeightVerification", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Cannot capture the closed panel's own view"])
        }
        try require(isClosed(panel) && bitmap.size == panel.panel.frame.size,
            "own-view capture cannot resize, expand or change the closed endpoint")
        return bitmap
    }

    static func compareGeometry(normal: IslandPanelController, music: IslandPanelController) throws {
        guard let a = normal.paintReceipt, let b = music.paintReceipt else {
            throw NSError(domain: "MusicClosedHeightVerification", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Missing actual closed paint receipts"])
        }
        let x = normal.panel.frame, y = music.panel.frame
        try require(isClosed(normal) && isClosed(music)
            && normal.geometry.notch == music.geometry.notch
            && normal.geometry.calibratedNotch == music.geometry.calibratedNotch
            && normal.geometry.contourFrame == music.geometry.contourFrame
            && !normal.geometry.showsMusicAccessories && music.geometry.musicAccessoryProgress == 1
            && x.height == y.height && x.minY == y.minY && x.maxY == y.maxY && y.width > x.width
            && a.frame.contour.rect.height == b.frame.contour.rect.height
            && b.frame.contour.rect.width > a.frame.contour.rect.width
            && x.minX + a.bodyBounds.midX == y.minX + b.bodyBounds.midX
            && a.bodyBounds.minY == b.bodyBounds.minY && a.bodyBounds.maxY == b.bodyBounds.maxY
            && a.railBounds.minY == b.railBounds.minY && a.railBounds.maxY == b.railBounds.maxY
            && a.frame.railOpacity == 1 && b.frame.railOpacity == 1,
            "music may widen the idle shell but cannot change native/body/rail height, bottom or calibration")
    }

    static func compareMaskedBottom(normal: NativeContourBitmap, music: NativeContourBitmap,
        normalPanel: IslandPanelController, musicPanel: IslandPanelController) throws -> (difference: Double, visible: Double) {
        let scale = CGFloat(music.scale), raw = musicPanel.geometry.notch
        let aFrame = normalPanel.panel.frame, bFrame = musicPanel.panel.frame
        let a = IslandContour(rect: normalPanel.geometry.contourRect(progress: 0),
            cornerAdjustment: normalPanel.geometry.shapeCalibration.corner, referenceDepth: raw.height)
        let b = IslandContour(rect: musicPanel.geometry.contourRect(progress: 0),
            cornerAdjustment: musicPanel.geometry.shapeCalibration.corner, referenceDepth: raw.height)
        // Only the common straight bottom stroke is comparable. Music intentionally
        // fills the wider wings; gradients and arc-length quota splits may differ.
        let left = max(raw.minX + raw.width / 4, max(aFrame.minX + a.rect.minX + a.corner + 2,
            bFrame.minX + b.rect.minX + b.corner + 2))
        let right = min(raw.maxX - raw.width / 4, min(aFrame.minX + a.rect.maxX - a.corner - 2,
            bFrame.minX + b.rect.maxX - b.corner - 2))
        let first = Int(ceil(left * scale)), last = Int(floor(right * scale))
        try require(last - first >= 8 * music.scale, "raw mask comparison needs a shared straight central bottom segment")
        var largest = 0.0, totalAlpha = 0.0, samples = 0
        for column in first..<last {
            let globalX = (CGFloat(column) + 0.5) / scale
            let ax = Int(((globalX - aFrame.minX) * scale).rounded(.down))
            let bx = Int(((globalX - bFrame.minX) * scale).rounded(.down))
            for row in 0..<music.representation.pixelsHigh {
                let topDown = (CGFloat(row) + 0.5) / scale
                guard topDown >= b.rect.maxY - 4 else { continue }
                let point = CGPoint(x: globalX, y: bFrame.maxY - topDown)
                // Removing the raw exclusion rectangle represents occlusion. It is
                // deliberately conservative and is not a measured physical contour.
                let masked = raw.contains(point)
                let aa = masked ? 0 : normal.pixel(x: ax, y: row).a
                let ba = masked ? 0 : music.pixel(x: bx, y: row).a
                largest = max(largest, abs(aa - ba)); totalAlpha += ba; samples += 1
            }
        }
        let visible = totalAlpha / Double(last - first) / Double(scale)
        let expected = Double(max(0, min(4, b.rect.maxY - raw.height)))
        try require(samples > 0 && largest <= 2.0 / 255
            && abs(visible - expected) <= 1 / Double(scale),
            "same raw mask must leave matching central bottom alpha coverage at the unchanged height")
        return (largest, visible)
    }

    static func export(_ bitmap: NativeContourBitmap, panel: IslandPanelController,
        commonFrame: CGRect, name: String) throws {
        let scale = CGFloat(bitmap.scale), margin = 8 * bitmap.scale
        let width = Int((commonFrame.width * scale).rounded()) + 2 * margin
        let height = Int((commonFrame.height * scale).rounded()) + 2 * margin
        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for y in 0..<height {
            for x in 0..<width {
                let global = CGPoint(x: commonFrame.minX + (CGFloat(x - margin) + 0.5) / scale,
                    y: commonFrame.maxY - (CGFloat(y - margin) + 0.5) / scale)
                let xx = Int(((global.x - panel.panel.frame.minX) * scale).rounded(.down))
                let yy = Int(((panel.panel.frame.maxY - global.y) * scale).rounded(.down))
                var red = 0.8, green = 0.8, blue = 0.8
                if xx >= 0 && yy >= 0 && xx < bitmap.representation.pixelsWide && yy < bitmap.representation.pixelsHigh {
                    let pixel = bitmap.pixel(x: xx, y: yy)
                    red = pixel.r * pixel.a + red * (1 - pixel.a)
                    green = pixel.g * pixel.a + green * (1 - pixel.a)
                    blue = pixel.b * pixel.a + blue * (1 - pixel.a)
                }
                if panel.geometry.notch.contains(global) { red = 0; green = 0; blue = 0 }
                output.setColor(NSColor(calibratedRed: CGFloat(red), green: CGFloat(green),
                    blue: CGFloat(blue), alpha: 1), atX: x, y: y)
            }
        }
        let directory = URL(fileURLWithPath: "dist/contour-rendering/music", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let png = output.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
#endif
