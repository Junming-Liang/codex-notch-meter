#if os(macOS)
import SwiftUI
import NotchCore

private enum MeterStyle {
    static let cardWidth: CGFloat = 340
    static let text = Color(red: 0.95, green: 0.96, blue: 0.97)
    static let secondary = Color(red: 0.67, green: 0.70, blue: 0.75)
    static let background = Color(red: 0.067, green: 0.075, blue: 0.094)
    static let raised = Color(red: 0.106, green: 0.118, blue: 0.145)
    static let mint = Color(red: 0.44, green: 0.84, blue: 0.69)
    static let amber = Color(red: 0.95, green: 0.75, blue: 0.41)
    static let coral = Color(red: 0.94, green: 0.50, blue: 0.53)
    static let unknown = Color(red: 0.55, green: 0.58, blue: 0.64)
}

private func quotaColor(_ remaining: Double?) -> Color {
    guard let remaining else { return MeterStyle.unknown }
    if remaining <= 10 { return MeterStyle.coral }
    if remaining <= 25 { return MeterStyle.amber }
    return MeterStyle.mint
}

private func windowTitle(_ window: QuotaWindow) -> String {
    guard let minutes = window.durationMinutes else { return "额度窗口" }
    if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
    if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
    return "\(minutes) 分钟"
}

private func resetSummary(_ window: QuotaWindow, at now: Date) -> String {
    guard let reset = window.resetsAt else { return "重置时间暂不可用" }
    let seconds = reset.timeIntervalSince(now)
    guard seconds > 0 else { return "重置时间已到，等待刷新确认" }
    let minutes = Int(ceil(seconds / 60))
    if minutes >= 1440 { return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时后重置" }
    if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟后重置" }
    return "\(minutes) 分钟后重置"
}

struct NotchRail: Shape {
    let left: Bool
    func path(in rect: CGRect) -> Path {
        let edge: CGFloat = left ? 3 : rect.width - 3
        let end: CGFloat = left ? rect.width : 0
        let direction: CGFloat = left ? 1 : -1
        var path = Path()
        path.move(to: CGPoint(x: edge, y: 0))
        path.addLine(to: CGPoint(x: edge, y: rect.height - 10))
        path.addQuadCurve(to: CGPoint(x: edge + direction * 7, y: rect.height - 3), control: CGPoint(x: edge, y: rect.height - 3))
        path.addLine(to: CGPoint(x: end, y: rect.height - 3))
        return path
    }
}

@MainActor
struct RailView: View {
    @ObservedObject var model: MeterModel
    let left: Bool
    let hovered: (Bool) -> Void
    var window: QuotaWindow? {
        let windows = model.bucket?.windows ?? []
        let index = left ? 0 : 1
        return windows.indices.contains(index) ? windows[index] : nil
    }
    var body: some View {
        let remaining = window?.remainingPercent
        let pending = window?.resetPending(at: model.now) ?? false
        let dim = model.degraded || pending
        ZStack {
            NotchRail(left: left).stroke(Color.black.opacity(0.9), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            NotchRail(left: left).stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            if let remaining {
                NotchRail(left: left).trim(from: 0, to: remaining / 100)
                    .stroke(quotaColor(remaining).opacity(dim ? 0.42 : 1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            } else {
                NotchRail(left: left).stroke(MeterStyle.unknown.opacity(0.75), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [3, 5]))
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.map(windowTitle) ?? "额度不可用")
        .accessibilityValue((remaining.map { "剩余 \(Int($0.rounded()))%" } ?? "未知") + (model.degraded ? "，上次读取" : "") + (pending ? "，等待刷新确认" : ""))
    }
}

@MainActor
private struct StatePill: View {
    let text: String
    var color: Color = MeterStyle.secondary
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
            .fixedSize()
    }
}

@MainActor
struct DetailView: View {
    @ObservedObject var model: MeterModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let hovered: (Bool) -> Void
    let refresh: () -> Void
    let settings: () -> Void
    private var borderOpacity: Double { contrast == .increased ? 0.28 : 0.10 }
    private var quotaListHeight: CGFloat {
        guard let buckets = model.snapshot?.buckets else { return 0 }
        let rows = buckets.reduce(0) { $0 + max(1, $1.windows.count) }
        let labels = buckets.count > 1 ? buckets.count * 24 : 0
        return min(365, CGFloat(rows * 145 + labels))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: model.error == nil ? "checkmark.shield" : "exclamationmark.circle")
                    .font(.system(size: 11)).padding(.top, 1)
                Text(model.status).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(model.error == nil ? MeterStyle.secondary : MeterStyle.amber)
            if let snapshot = model.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(snapshot.buckets) { bucket in
                            VStack(alignment: .leading, spacing: 8) {
                                if snapshot.buckets.count > 1 {
                                    HStack {
                                        Text(bucket.name).lineLimit(1).font(.system(size: 11, weight: .semibold))
                                        Spacer()
                                        if bucket.id == model.bucket?.id { Text("刘海显示").font(.system(size: 10)).foregroundStyle(MeterStyle.secondary) }
                                    }.padding(.horizontal, 2)
                                }
                                ForEach(bucket.windows) { window in
                                    QuotaRow(window: window, now: model.now, degraded: model.degraded)
                                }
                                if bucket.windows.isEmpty { emptyQuota("这个额度组暂未提供窗口数据") }
                            }
                        }
                    }
                }.frame(height: quotaListHeight)
            } else { emptyQuota(model.refreshing ? "正在读取 Codex 账户…" : "暂时没有额度数据") }
            Rectangle().fill(Color.white.opacity(borderOpacity)).frame(height: 1)
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text(model.snapshot.map { "读取于 " + $0.fetchedAt.formatted(date: .omitted, time: .shortened) } ?? "尚未读取")
                        .font(.system(size: 10)).monospacedDigit()
                }.foregroundStyle(MeterStyle.secondary)
                Spacer()
                Button(action: settings) { Label("设置", systemImage: "slider.horizontal.3").font(.system(size: 11)).frame(minHeight: 28) }
                    .buttonStyle(.plain).foregroundStyle(MeterStyle.secondary)
                    .help("打开设置")
            }
        }
        .padding(16)
        .frame(width: MeterStyle.cardWidth)
        .foregroundStyle(MeterStyle.text)
        .background {
            if reduceTransparency { MeterStyle.background }
            else { MeterStyle.background.opacity(0.96).background(.ultraThinMaterial) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(borderOpacity), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .onHover(perform: hovered)
    }
    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MeterStyle.mint).frame(width: 28, height: 28)
                .background(MeterStyle.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Notch Meter").font(.system(size: 13, weight: .semibold))
                Text("额度概览").font(.system(size: 11)).foregroundStyle(MeterStyle.secondary)
            }
            Spacer(minLength: 4)
            if model.demo { StatePill(text: "演示数据", color: MeterStyle.amber) }
            Button(action: refresh) {
                ZStack {
                    if model.refreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
                }.frame(width: 28, height: 28)
            }.buttonStyle(.plain).disabled(model.refreshing || model.demo)
                .help("刷新额度").accessibilityLabel("刷新额度")
        }
    }
    private func emptyQuota(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("—").font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(message).font(.system(size: 12, weight: .medium))
            Text("缺失数据不会被当作满额。可在设置中检查 Codex 连接。")
                .font(.system(size: 11)).foregroundStyle(MeterStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(MeterStyle.raised, in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
struct QuotaRow: View {
    let window: QuotaWindow
    let now: Date
    let degraded: Bool
    private var pending: Bool { window.resetPending(at: now) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(windowTitle(window)).font(.system(size: 12, weight: .medium))
                Spacer()
                if pending { StatePill(text: "等待确认", color: MeterStyle.amber) }
                else if degraded { StatePill(text: "上次读取", color: MeterStyle.amber) }
                else if window.remainingPercent == nil { StatePill(text: "未知") }
                else { Text("额度周期").font(.system(size: 10)).foregroundStyle(MeterStyle.secondary) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(window.remainingPercent.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                if window.remainingPercent != nil {
                    Text("%").font(.system(size: 15, weight: .medium)).foregroundStyle(MeterStyle.secondary)
                    Text("剩余").font(.system(size: 11)).foregroundStyle(MeterStyle.secondary).padding(.leading, 3)
                } else { Text("暂无额度数据").font(.system(size: 11)).foregroundStyle(MeterStyle.secondary) }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    if let remaining = window.remainingPercent {
                        Capsule().fill(quotaColor(remaining).opacity(degraded || pending ? 0.45 : 1))
                            .frame(width: geometry.size.width * remaining / 100)
                    }
                }
            }.frame(height: 6)
                .accessibilityLabel("剩余额度")
                .accessibilityValue(window.remainingPercent.map { String(format: "%.0f%%", $0) } ?? "未知")
            VStack(alignment: .leading, spacing: 3) {
                Text(resetSummary(window, at: now)).font(.system(size: 12))
                if let reset = window.resetsAt {
                    Text(reset.formatted(date: .abbreviated, time: .shortened) + " · " + (TimeZone.current.abbreviation(for: reset) ?? TimeZone.current.identifier))
                        .font(.system(size: 10)).foregroundStyle(MeterStyle.secondary)
                }
            }.foregroundStyle(pending ? MeterStyle.amber : MeterStyle.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(MeterStyle.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var model: MeterModel
    let chooseExecutable: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MeterStyle.mint).frame(width: 46, height: 46)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex Notch Meter").font(.system(size: 20, weight: .semibold))
                    Text("抬眼看见 Codex 剩余额度").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("在刘海边缘显示额度进度线", isOn: $model.overlayEnabled)
                    if let buckets = model.snapshot?.buckets, buckets.count > 1 {
                        Picker("显示的额度组", selection: $model.preferredBucket) {
                            ForEach(buckets) { bucket in Text(bucket.name).tag(bucket.id) }
                        }
                    }
                    Text("没有刘海的显示器使用菜单栏。悬停进度线或点击菜单栏图标，即可查看完整额度。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } label: { Label("显示", systemImage: "display").font(.system(size: 12, weight: .semibold)) }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.executablePath.isEmpty ? "自动查找 · PATH / Homebrew" : model.executablePath)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        .lineLimit(3)
                    HStack {
                        Button("选择 Codex…", action: chooseExecutable)
                        Button("自动查找") { model.setExecutable("") }
                    }.controlSize(.small)
                    Text("只选择已安装且信任的官方 Codex CLI。请在 Codex 中完成登录；本应用不索取密码，也不读取凭据文件。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } label: { Label("Codex 连接", systemImage: "link").font(.system(size: 12, weight: .semibold)) }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("只读账户接口 · 不发送模型任务", systemImage: "checkmark.shield").font(.system(size: 12))
                    Text("不收集聊天记录，不上传额度，不开机自启。不需要辅助功能或屏幕录制权限。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: model.error == nil ? "circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 7)).foregroundStyle(model.error == nil ? MeterStyle.mint : MeterStyle.amber).padding(.top, 4)
                        Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } label: { Label("隐私与状态", systemImage: "lock.shield").font(.system(size: 12, weight: .semibold)) }
            HStack {
                Text("v0.1.0 · 开源预览版").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("刷新额度") { model.refresh() }.disabled(model.refreshing || model.demo)
                Button("退出") { NSApplication.shared.terminate(nil) }
            }.controlSize(.small)
        }.padding(24).frame(width: 480)
    }
}
#endif
