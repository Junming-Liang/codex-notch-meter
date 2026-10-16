#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Fixed compact content inside the existing notice-sized contour. Missing
/// lyrics have an honest status; playback does not expand an empty quota card.
@MainActor
struct MusicCompactView: View {
    @ObservedObject var music: MusicLyricsController
    var body: some View {
        if music.isPlayingForPresentation {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "music.note")
                    Text(music.trackTitle.isEmpty ? "Apple Music" : music.trackTitle).lineLimit(1)
                    Spacer(minLength: 4)
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(music.line.isEmpty ? music.statusText : music.line)
                    .font(.system(size: 12, weight: music.line.isEmpty ? .regular : .medium))
                    .foregroundStyle(music.line.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 2).foregroundStyle(.white).environment(\.colorScheme, .dark)
                .accessibilityElement(children: .combine)
        }
    }
}

/// Fits inside the existing scrollable detail content; never sizes the island.
@MainActor
struct MusicLyricRow: View {
    @ObservedObject var music: MusicLyricsController
    var body: some View {
        if music.enabled && music.isPlayingForPresentation {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "music.note").font(.system(size: 9))
                    Text(music.trackTitle.isEmpty ? "Apple Music" : music.trackTitle)
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(music.sourceLabel).font(.system(size: 8)).lineLimit(1)
                }.foregroundStyle(.secondary)
                Text(music.line.isEmpty ? music.statusText : music.line)
                    .font(.system(size: 11, weight: music.line.isEmpty ? .regular : .medium))
                    .foregroundStyle(music.line.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if !music.line.isEmpty && music.statusText != "同步歌词" {
                    Text(music.statusText).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(.vertical, 4)
                .accessibilityElement(children: .combine)
        }
    }
}

@MainActor
struct MusicLyricsSettings: View {
    @ObservedObject var music: MusicLyricsController
    @State private var confirmOnlineLookup = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("播放时自动展开 Apple Music 歌词", isOn: Binding(
                    get: { music.enabled }, set: { music.setEnabled($0) }))
                    .disabled(music.synthetic)
                Text("默认关闭。播放时显示紧凑歌词，暂停时收起；悬停可保持详情，额度提示结束后返回歌词。启用时会请求读取 Music 当前歌曲与播放位置的自动化权限；不会打开 Music 或控制播放。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if music.enabled {
                    Text(music.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                    HStack {
                        Button("为当前歌曲导入 LRC…", action: chooseLocalLyrics)
                            .disabled(!music.canImport || music.synthetic)
                        if music.hasLocalLyrics {
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
