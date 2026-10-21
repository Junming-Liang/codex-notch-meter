#if os(macOS)
import SwiftUI
import AppKit
import NotchCore

private enum MeterStyle {
    static let cardWidth: CGFloat = 340
    static let text = Color(red: 0.95, green: 0.96, blue: 0.97)
    static let secondary = Color(red: 0.67, green: 0.70, blue: 0.75)
    static let background = Color(red: 0.067, green: 0.075, blue: 0.094)
    static let raised = Color(red: 0.106, green: 0.118, blue: 0.145)
    static let mint = Color(red: 0.44, green: 0.84, blue: 0.69)
    static let sky = Color(red: 0.48, green: 0.72, blue: 0.96)
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

func quotaPaint(_ remaining: Double?, theme: MeterTheme, phase: Double = 0) -> AnyShapeStyle {
    guard let remaining, remaining > 25 else { return AnyShapeStyle(quotaColor(remaining)) }
    let colors: [Color]
    switch theme {
    case .standard: return AnyShapeStyle(MeterStyle.mint)
    case .rainbow:
        // Only color phase moves. The separate path trim remains the actual quota fraction.
        colors = (0...24).map { index in
            Color(hue: (Double(index) / 24 + phase).truncatingRemainder(dividingBy: 1), saturation: 0.64, brightness: 0.98)
        }
    case .aurora: colors = [Color(red: 0.40, green: 0.91, blue: 0.89), Color(red: 0.71, green: 0.60, blue: 1)]
    case .sunset: colors = [Color(red: 0.98, green: 0.81, blue: 0.53), Color(red: 0.93, green: 0.57, blue: 0.50)]
    case .ice: colors = [Color(red: 0.71, green: 0.85, blue: 1), Color(red: 0.51, green: 0.66, blue: 0.82)]
    }
    return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
}

func windowTitle(_ window: QuotaWindow) -> String {
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

/// One uninterrupted U: upper left → lower left → bottom → lower right → upper right.
struct NotchRail: Shape {
    var drawingRect: CGRect? = nil
    var progress: Double = 0
    var cornerAdjustment: Double = 0
    var referenceDepth: CGFloat = 32
    func path(in viewport: CGRect) -> Path {
        contourPath(IslandContour(rect: drawingRect ?? viewport, progress: progress,
            cornerAdjustment: cornerAdjustment, referenceDepth: referenceDepth), inset: 2, closed: false)
    }
}

@MainActor
struct RailView: View {
    @ObservedObject var model: MeterModel
    var drawingRect: CGRect? = nil
    var progress: Double = 0
    var cornerAdjustment: Double = 0
    var referenceDepth: CGFloat = 32
    let hovered: (Bool) -> Void
    var window: QuotaWindow? { model.primaryWindow }
    var body: some View {
        let remaining = window?.remainingPercent
        let pending = window?.resetPending(at: model.now) ?? false
        let dim = model.degraded || pending
        let paint = quotaPaint(remaining, theme: model.theme, phase: model.skinPhase)
        // Wider paint covers the same circular centerline; frame, path and clip stay unchanged.
        ZStack {
            NotchRail(drawingRect: drawingRect, progress: progress, cornerAdjustment: cornerAdjustment, referenceDepth: referenceDepth).stroke(Color.black, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            if let remaining, remaining > 0 {
                NotchRail(drawingRect: drawingRect, progress: progress, cornerAdjustment: cornerAdjustment, referenceDepth: referenceDepth).trim(from: 0, to: remaining / 100)
                    .stroke(paint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round)).opacity(dim ? 0.55 : 1)
            }
        }
        .contentShape(Rectangle()).onHover(perform: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.map { "主额度 · " + windowTitle($0) } ?? "额度不可用")
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

private struct QuitFramePreference: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

@MainActor
struct DetailView: View {
    @ObservedObject var model: MeterModel
    var embedded = false
    var embeddedHeight: CGFloat? = nil
    var quitFrameChanged: (CGRect) -> Void = { _ in }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let hovered: (Bool) -> Void
    let refresh: () -> Void
    let settings: () -> Void
    let quit: () -> Void
    private var borderOpacity: Double { contrast == .increased ? 0.28 : 0.10 }
    private var quotaListHeight: CGFloat {
        guard let buckets = model.snapshot?.buckets else { return 0 }
        let rows = buckets.reduce(0) { $0 + max(1, $1.windows.count) }
        let labels = buckets.count > 1 ? buckets.count * 24 : 0
        let available = embedded ? max(80, (embeddedHeight ?? 472) - 220) : 365
        return min(available, CGFloat(rows * 145 + labels))
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
                        if model.error == nil { MusicLyricRow(music: model.music) }
                        ForEach(snapshot.buckets) { bucket in
                            VStack(alignment: .leading, spacing: 8) {
                                if snapshot.buckets.count > 1 {
                                    HStack {
                                        Text(bucket.name).lineLimit(1).font(.system(size: 11, weight: .semibold))
                                        Spacer()
                                        if bucket.id == model.bucket?.id { Text("当前额度").font(.system(size: 10)).foregroundStyle(MeterStyle.secondary) }
                                    }.padding(.horizontal, 2)
                                }
                                ForEach(bucket.windows) { window in
                                    QuotaRow(window: window, now: model.now, degraded: model.degraded, theme: model.theme, phase: model.skinPhase, selected: window.id == model.primaryWindow?.id)
                                }
                                if bucket.windows.isEmpty { emptyQuota("这个额度组暂未提供窗口数据") }
                            }
                        }
                    }
                }.frame(height: quotaListHeight)
            } else { emptyQuota(model.refreshing ? "正在读取 Codex 账户…" : "暂时没有额度数据") }
            if embedded { Spacer(minLength: 0) }
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
                Button(action: quit) { Label("退出", systemImage: "power").font(.system(size: 11, weight: .semibold)).frame(minHeight: 28) }
                    .buttonStyle(.plain).foregroundStyle(MeterStyle.text)
                    .help("退出 Codex Notch Meter").accessibilityLabel("退出 Codex Notch Meter")
                    .background(GeometryReader { proxy in Color.clear.preference(key: QuitFramePreference.self, value: proxy.frame(in: .named("quotaDetails"))) })
            }
        }
        .padding(16)
        .frame(width: MeterStyle.cardWidth, height: embeddedHeight, alignment: .top)
        .coordinateSpace(name: "quotaDetails")
        .onPreferenceChange(QuitFramePreference.self, perform: quitFrameChanged)
        .foregroundStyle(MeterStyle.text)
        .background {
            if embedded { Color.black }
            else if reduceTransparency { MeterStyle.background }
            else { MeterStyle.background.opacity(0.96).background(.ultraThinMaterial) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(embedded ? 0 : borderOpacity), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .onHover(perform: hovered)
    }
    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(quotaPaint(100, theme: model.theme, phase: model.skinPhase)).frame(width: 28, height: 28)
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
    var theme: MeterTheme = .standard
    var phase: Double = 0
    var selected = false
    private var pending: Bool { window.resetPending(at: now) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(windowTitle(window)).font(.system(size: 12, weight: .medium))
                if selected { Text("当前额度").font(.system(size: 9)).foregroundStyle(MeterStyle.secondary) }
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
                    Capsule().fill(Color.black)
                    if let remaining = window.remainingPercent {
                        Capsule().fill(quotaPaint(remaining, theme: theme, phase: phase)).opacity(degraded || pending ? 0.45 : 1)
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
    @ObservedObject var login: LoginSettingsModel
    let chooseExecutable: () -> Void
    let startDebugCapture: () -> Void
    let quit: () -> Void
    private func shapeAdjustmentRow(_ title: String, value: Double, limit: Double, changed: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("−") { changed(value - 0.5) }.disabled(value <= -limit)
                .accessibilityLabel(title + "减少 0.5 点")
            Text(String(format: "%+.1f pt", value)).font(.system(size: 11, design: .monospaced)).frame(width: 64)
            Button("+") { changed(value + 0.5) }.disabled(value >= limit)
                .accessibilityLabel(title + "增加 0.5 点")
            Button("重置") { changed(0) }.disabled(value == 0)
        }.controlSize(.small).disabled(model.calibrationDisplays.isEmpty)
    }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
            DebugCaptureSettingsView(capture: model.debugCapture, start: startDebugCapture)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("在刘海边缘显示额度进度线", isOn: $model.overlayEnabled)
                    Toggle("额度变化时显示提示", isOn: $model.refreshNoticesEnabled)
                    Picker("提示停留时长", selection: $model.noticeDuration) {
                        ForEach(NoticeDuration.allCases) { duration in
                            Text("\(duration.title) · \(Int(duration.seconds)) 秒").tag(duration)
                        }
                    }.disabled(!model.refreshNoticesEnabled)
                    Text("完全展开后开始计时；鼠标停留时保持展开。未变化的刷新不弹出提示。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("外观皮肤", selection: $model.theme) {
                        ForEach(MeterTheme.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("皮肤动效", isOn: $model.skinMotionEnabled).disabled(!model.theme.supportsMotion)
                    if model.theme.supportsMotion {
                        Picker("流动速度", selection: $model.skinSpeed) {
                            Text("舒缓 · 12 秒").tag(SkinMotionSpeed.slow)
                            Text("标准 · 8 秒").tag(SkinMotionSpeed.normal)
                        }.disabled(!model.skinMotionEnabled)
                    }
                    Text("彩虹颜色缓慢流动，额度长度不动。减少动态效果、低电量模式或屏幕休眠时自动静止。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let buckets = model.snapshot?.buckets, buckets.count > 1 {
                        Picker("显示的额度组", selection: $model.preferredBucket) {
                            ForEach(buckets) { bucket in Text(bucket.name).tag(bucket.id) }
                        }
                    }
                    if let windows = model.bucket?.windows, !windows.isEmpty {
                        Picker("刘海主额度", selection: Binding(get: {
                            windows.contains(where: { $0.id == model.preferredQuota }) ? model.preferredQuota : ""
                        }, set: { model.preferredQuota = $0 })) {
                            Text("自动 · 最短周期").tag("")
                            ForEach(windows) { Text(windowTitle($0)).tag($0.id) }
                        }
                    }
                    Text("整条轮廓显示一组额度：从左填充，用掉后从右端缩回。展开卡片保留全部额度。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text("根据当前屏幕避让区域自动匹配位置与圆弧；显示模式改变时自动重新计算。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("高级：此屏幕轮廓微调") {
                        if model.calibrationDisplays.count > 1 {
                            Picker("校准的内建屏幕", selection: $model.selectedCalibrationDisplayID) {
                                ForEach(model.calibrationDisplays) { Text($0.name).tag($0.id) }
                            }
                        }
                        HStack {
                            Text("水平微调")
                            Spacer()
                            Button("−") { model.setHorizontalAdjustment(model.selectedHorizontalAdjustment - 0.5) }
                                .accessibilityLabel("刘海轮廓左移 0.5 点")
                                .disabled(model.selectedHorizontalAdjustment <= (model.selectedCalibrationDisplay?.minimum ?? -8))
                            Text(String(format: "%+.1f pt", model.selectedHorizontalAdjustment))
                                .font(.system(size: 11, design: .monospaced)).frame(width: 64)
                            Button("+") { model.setHorizontalAdjustment(model.selectedHorizontalAdjustment + 0.5) }
                                .accessibilityLabel("刘海轮廓右移 0.5 点")
                                .disabled(model.selectedHorizontalAdjustment >= (model.selectedCalibrationDisplay?.maximum ?? 8))
                            Button("重置") { model.setHorizontalAdjustment(0) }.disabled(!model.hasStoredHorizontalAdjustment)
                        }.controlSize(.small).disabled(model.calibrationDisplays.isEmpty)
                        Text(model.calibrationDisplays.isEmpty ? "连接带刘海的内建屏幕后可校准。" : "默认 0；负值向左，正值向右。每次 0.5 pt，最多 ±8 pt，仅在本机记住此屏幕的设置。")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        shapeAdjustmentRow("轮廓宽度", value: model.selectedShapeCalibration.width, limit: 16) { value in
                            let current = model.selectedShapeCalibration
                            model.setShapeCalibration(ContourCalibration(width: value, depth: current.depth, corner: current.corner))
                        }
                        shapeAdjustmentRow("底部位置", value: model.selectedShapeCalibration.depth, limit: 6) { value in
                            let current = model.selectedShapeCalibration
                            model.setShapeCalibration(ContourCalibration(width: current.width, depth: value, corner: current.corner))
                        }
                        shapeAdjustmentRow("圆角调整", value: model.selectedShapeCalibration.corner, limit: 6) { value in
                            let current = model.selectedShapeCalibration
                            model.setShapeCalibration(ContourCalibration(width: current.width, depth: current.depth, corner: value))
                        }
                        HStack {
                            Text("调整会实时显示，仅记住此屏幕。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Button("重置此屏幕全部校准") { model.resetCalibration() }
                                .disabled(!model.hasStoredCalibration).controlSize(.small)
                        }
                        Text("宽度是总宽度变化；底部正值向下；圆角正值更圆。默认均为 0。系统只提供避让区域，自动圆弧是依据公开参考的近似曲线，并非硬件测量值。")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("没有刘海的显示器使用菜单栏。悬停进度线或点击菜单栏图标，即可查看完整额度。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } label: { Label("显示", systemImage: "display").font(.system(size: 12, weight: .semibold)) }
            MusicLyricsSettings(music: model.music)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("登录时启动", isOn: Binding(get: { login.isEnabled }, set: { login.setEnabled($0) }))
                        .disabled(login.synthetic || (!login.canEnable && !login.isEnabled))
                        .accessibilityValue(login.systemStatusText)
                    Text(login.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if login.issue != nil || login.location != .applications {
                        Text("系统记录：" + login.systemStatusText).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if login.needsApproval {
                        HStack {
                            Button("在系统设置中批准…") { login.openSettings() }
                            Button("取消待批准请求") { login.cancelPending() }
                        }.controlSize(.small).disabled(login.synthetic)
                    } else if login.status == .enabled && login.location != .applications {
                        Button("停用系统登录项") { login.cancelPending() }.controlSize(.small).disabled(login.synthetic)
                    }
                    Text("默认关闭，仅在你选择后请求启用。此预览版为临时签名，系统可能拒绝注册；安装 DMG 不会自动开启。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("打开系统登录项…") { login.openSettings() }.controlSize(.small).disabled(login.synthetic)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } label: { Label("启动", systemImage: "power.circle").font(.system(size: 12, weight: .semibold)) }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.executablePath.isEmpty ? "自动查找 · Codex 桌面应用 / CLI" : model.executablePath)
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
                    Text("不收集聊天记录，不上传额度。登录时启动由你选择。不需要辅助功能或屏幕录制权限。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: model.error == nil ? "circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 7)).foregroundStyle(model.error == nil ? MeterStyle.mint : MeterStyle.amber).padding(.top, 4)
                        Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let notice = model.displayNotice {
                        Text(notice).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } label: { Label("隐私与状态", systemImage: "lock.shield").font(.system(size: 12, weight: .semibold)) }
                }
            }
            HStack {
                Text("v1.1.3 · 正式版").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("刷新额度") { model.refresh() }.disabled(model.refreshing || model.demo)
                Button(action: quit) { Label("退出应用", systemImage: "power") }.help("退出 Codex Notch Meter（⌘Q）")
            }.controlSize(.small)
        }.padding(24).frame(width: 480, height: min(720, max(520, (NSScreen.main?.visibleFrame.height ?? 800) - 80)))
            .onAppear { login.refresh() }
    }
}
@MainActor
private struct DebugCaptureSettingsView: View {
    @ObservedObject var capture: DebugCaptureController
    let start: () -> Void
    var body: some View {
        GroupBox("抖动诊断（默认关闭）") {
            VStack(alignment: .leading, spacing: 10) {
                Text(capture.status).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(capture.status)
                Text("1. 开始录制 → 2. 关闭设置和菜单 → 3. 复现抖动 → 4. 右键菜单栏图标，停止并导出。设置打开时会抑制音乐展示，不能在此页复现。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(capture.hasCapture ? "重新开始录制" : "开始录制", action: start)
                        .disabled(capture.isRecording)
                    Button("停止录制") { capture.stop() }.disabled(!capture.isRecording)
                    Button(capture.isRecording ? "停止并导出…" : "导出日志…") { capture.stopAndExport() }
                        .disabled(!capture.hasCapture)
                }.controlSize(.small)
                Text("仅内存保留最近的有界诊断事件；无账户、歌曲/歌词正文、文件路径、截图或完整鼠标轨迹。不自动上传。重新开始或退出会清除上一份日志。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(4)
        }
    }
}
#endif
