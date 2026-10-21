#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Actual text metrics drive a bounded target height; line breaks do not change
/// the geometry map or start a second animation. The first line stays dominant.
@MainActor
enum MusicPreviewLayout {
    static let currentFontSize: CGFloat = 18
    static let nextFontSize: CGFloat = 12
    private struct MeasurementStyle: Equatable {
        let currentFontSize: CGFloat
        let nextFontSize: CGFloat
        let currentFontWeight: CGFloat
        let maximumHeight: CGFloat = 10_000
        let wrappingTolerance: CGFloat = 1
        let wrappedExtra: CGFloat = 22
        let currentOnlyHeight: CGFloat = 48
        let withNextHeight: CGFloat = 68
    }
    private static let measurementStyle = MeasurementStyle(currentFontSize: currentFontSize,
        nextFontSize: nextFontSize, currentFontWeight: NSFont.Weight.semibold.rawValue)
    private static func normalizedWidth(_ width: CGFloat) -> CGFloat {
        width.isFinite ? max(1, width) : 1
    }
    static func contentHeight(line: String, nextLine: String, width: CGFloat) -> CGFloat {
        measure(line: line, hasNextLine: !nextLine.isEmpty, width: normalizedWidth(width), style: measurementStyle)
    }
    private static func measure(line: String, hasNextLine: Bool, width: CGFloat, style: MeasurementStyle) -> CGFloat {
        let font = NSFont.systemFont(ofSize: style.currentFontSize, weight: NSFont.Weight(rawValue: style.currentFontWeight))
        let bounds = (line as NSString).boundingRect(with: CGSize(width: width, height: style.maximumHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        let oneLine = ceil(font.ascender - font.descender + font.leading)
        let extra: CGFloat = bounds.height > oneLine + style.wrappingTolerance ? style.wrappedExtra : 0
        return (hasNextLine ? style.withNextHeight : style.currentOnlyHeight) + extra
    }

    /// Two single-value slots let compact and prewarmed details share measurements
    /// without evicting one another on every animation frame. No history is retained.
    @MainActor
    struct Cache {
        private struct Key: Equatable {
            let trackRevision: UUID
            let line: String
            let hasNextLine: Bool
            let width: CGFloat
            let style: MeasurementStyle
        }
        private struct Entry {
            let key: Key
            let height: CGFloat
        }
        private var recent: Entry?
        private var previous: Entry?
        private(set) var syntheticMeasurementCount: UInt64 = 0

        mutating func clear() { recent = nil; previous = nil }

        mutating func contentHeight(trackRevision: UUID, line: String, nextLine: String, width: CGFloat,
                                    countSyntheticMeasurement: Bool = false) -> CGFloat {
            let key = Key(trackRevision: trackRevision, line: line, hasNextLine: !nextLine.isEmpty,
                width: normalizedWidth(width), style: measurementStyle)
            if let recent, recent.key == key { return recent.height }
            if let previous, previous.key == key {
                self.previous = recent; recent = previous
                return previous.height
            }
            let height = measure(line: line, hasNextLine: key.hasNextLine, width: key.width, style: key.style)
            if countSyntheticMeasurement { syntheticMeasurementCount &+= 1 }
            previous = recent; recent = Entry(key: key, height: height)
            return height
        }
    }
}

/// Only real decoded thumbnail data or a neutral placeholder is displayed.
/// The gently moving playing glyph indicates playback state without audio analysis.
@MainActor
struct MusicClosedAccessories: View {
    @ObservedObject var music: MusicLyricsController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let left: CGRect
    let right: CGRect
    var visible = true
    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let image = music.artworkImage { Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFill() }
                else { Image(systemName: "music.note").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.12)) }
            }.frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 4))
                .offset(x: left.minX + 7, y: max(0, (left.height - 20) / 2))
            MusicPlayingIndicator(active: music.isFreshPlaying && visible, reduceMotion: reduceMotion)
                .frame(width: 20, height: 20)
                .offset(x: right.maxX - 27, y: max(0, (right.height - 20) / 2))
        }.accessibilityElement(children: .ignore).accessibilityLabel("Apple Music 正在播放")
    }

}

/// Approved B: small song title, left-aligned current cue, quieter actual next cue.
@MainActor
struct MusicCompactView: View {
    @ObservedObject var music: MusicLyricsController
    var body: some View {
        if music.isPlayingForPresentation && music.lyricsModeEnabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(music.trackTitle).lineLimit(1)
                    if !music.isSynchronized { Text("未同步").lineLimit(1) }
                    Spacer(minLength: 4)
                }.font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 0.63, green: 0.64, blue: 0.67))
                Text(music.line)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 0.97, green: 0.97, blue: 0.98))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !music.nextLine.isEmpty {
                    Text(music.nextLine).font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.44, green: 0.45, blue: 0.49))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 2).environment(\.colorScheme, .dark)
                .accessibilityElement(children: .combine)
        }
    }
}

/// The same hierarchy is used inside scrollable manual details, with source
/// attribution retained for imported/community lyrics.
@MainActor
struct MusicLyricRow: View {
    @ObservedObject var music: MusicLyricsController
    var body: some View {
        if music.enabled && music.isPlayingForPresentation && music.lyricsModeEnabled {
            VStack(alignment: .leading, spacing: 4) {
                MusicCompactView(music: music)
                Text(music.sourceLabel).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.vertical, 4).accessibilityElement(children: .combine)
        }
    }
}

@MainActor
struct MusicLyricsSettings: View {
    @ObservedObject var music: MusicLyricsController
    @State private var confirmOnlineLookup = false
    @State private var confirmAMLLLookup = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Apple Music 歌词与播放指示", isOn: Binding(
                    get: { music.enabled }, set: { music.setEnabled($0) }))
                    .disabled(music.synthetic)
                Text("默认关闭。启用后播放时保持收起；鼠标从左向右划过顶部显示匹配歌词，反向划过关闭。暂停收起，恢复时保留所选模式；额度提示临时优先。启用时请求读取 Music 当前歌曲、播放位置和封面的自动化权限；不会打开 Music 或控制播放。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if music.enabled {
                    Label("本设置窗口可见时，顶部音乐显示与歌词手势会暂停；关闭窗口后恢复。歌词读取和匹配仍继续。", systemImage: "info.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("musicSettingsPresentationNotice")
                    Text(music.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let diagnostic = music.providerDiagnosticText {
                        Text(diagnostic).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if music.needsAuthorization {
                        Button("请求 Music 授权…") { music.requestAuthorization() }
                            .controlSize(.small).disabled(music.synthetic)
                    }
                    Toggle("使用 LRCLIB 在线匹配歌词", isOn: Binding(
                        get: { music.onlineLookupEnabled }, set: { value in
                            if value { confirmOnlineLookup = true }
                            else { music.setOnlineLookupEnabled(false) }
                        })).disabled(music.synthetic)
                    Text("单独选择开启后，会把歌曲名、歌手、专辑和时长发送给 LRCLIB 以匹配社区歌词。不会发送 Apple 账户、令牌或额度；歌词可能缺失或不匹配，并非 Apple 官方歌词。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("使用 AMLL 作为备用歌词源", isOn: Binding(
                        get: { music.amllFallbackEnabled }, set: { value in
                            if value { confirmAMLLLookup = true }
                            else { music.setAMLLFallbackEnabled(false) }
                        })).disabled(music.synthetic)
                    Text("默认关闭。启用后，LRCLIB 无可用歌词或暂时失败时，将歌曲名、歌手和专辑发送至 api.amll.dev。需同时开启 LRCLIB；只接受唯一且完整匹配的记录，覆盖率不保证。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("为当前歌曲导入 LRC…", action: chooseLocalLyrics)
                            .disabled(!music.canImport || music.synthetic)
                        if music.canClearLocalLyrics {
                            Button("清除本次导入") { music.clearLocalLyrics() }.disabled(music.synthetic)
                        }
                    }.controlSize(.small)
                    Text("本地 UTF-8 LRC / 文本只在当前歌曲生效，不上传。没有时间戳时标为未同步。部分系统版本的流媒体播放信息可能不可用。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: { Label("Apple Music 歌词", systemImage: "music.note").font(.system(size: 12, weight: .semibold)) }
        .confirmationDialog("启用 LRCLIB 在线歌词？", isPresented: $confirmOnlineLookup, titleVisibility: .visible) {
            Button("启用并发送歌曲信息") { music.setOnlineLookupEnabled(true) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将当前及后续播放歌曲的名称、歌手、专辑和时长发送至 lrclib.net，仅用于匹配社区歌词。可随时在这里关闭；本地导入不需要联网。")
        }
        .confirmationDialog("启用 AMLL 备用歌词？", isPresented: $confirmAMLLLookup, titleVisibility: .visible) {
            Button("启用并向 AMLL 发送歌曲信息") { music.setAMLLFallbackEnabled(true) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将当前及后续歌曲的名称、歌手和专辑发送至 api.amll.dev，用于 LRCLIB 后备匹配。不会发送 Apple 账户、令牌或本地文件。可随时关闭；社区歌词并非 Apple 官方歌词。")
        }
    }
    private func chooseLocalLyrics() {
        guard !music.synthetic, let selectionToken = music.importSelectionToken else { return }
        let panel = NSOpenPanel()
        panel.title = "为当前歌曲选择歌词"
        panel.message = "仅在本机读取所选 UTF-8 LRC 或文本，切换歌曲后不再使用。"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "lrc") ?? .text]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in music.importLyrics(from: url, for: selectionToken) }
        }
    }
}
#endif
