#if os(macOS)
import SwiftUI
import NotchCore

private struct CompactQuitFrame: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Content lives inside the one connected black island; this view has no card background.
@MainActor
struct CompactDetailView: View {
    @ObservedObject var model: MeterModel
    let height: CGFloat
    let quitFrameChanged: (CGRect) -> Void
    let refresh: () -> Void
    let settings: () -> Void
    let quit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Codex").font(.system(size: 12, weight: .semibold))
                if model.demo { Text("演示数据").font(.system(size: 9)).foregroundStyle(.orange) }
                Spacer()
                Text(model.degraded ? "上次读取" : "额度概览").font(.system(size: 10)).foregroundStyle(.secondary)
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 24, height: 22)
                }.buttonStyle(.plain).help("刷新额度").accessibilityLabel("刷新额度")
                    .disabled(model.refreshing || model.demo)
            }.frame(height: 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if model.error != nil {
                        Text(model.status).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if let snapshot = model.snapshot {
                        ForEach(snapshot.buckets) { bucket in
                            if snapshot.buckets.count > 1 {
                                Text(bucket.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            ForEach(bucket.windows) { window in
                                compactRow(window)
                            }
                            if bucket.windows.isEmpty { Text("暂无额度窗口").font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                    } else {
                        Text("—").font(.system(size: 24, weight: .semibold))
                        Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.frame(height: max(48, height - 82))
            HStack {
                Button(action: settings) { Label("设置", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.plain).help("打开设置")
                Spacer()
                Text(model.snapshot.map { $0.fetchedAt.formatted(date: .omitted, time: .shortened) } ?? "未读取")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Button(action: quit) { Label("退出", systemImage: "power").fontWeight(.semibold).frame(minHeight: 28) }
                    .buttonStyle(.plain).help("退出 Codex Notch Meter").accessibilityLabel("退出 Codex Notch Meter")
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: CompactQuitFrame.self, value: proxy.frame(in: .named("compactDetails")))
                    })
            }.font(.system(size: 11)).frame(height: 28).padding(.horizontal, 2)
        }
        .padding(.bottom, 16)
        .frame(width: 304, height: height, alignment: .top)
        .coordinateSpace(name: "compactDetails")
        .onPreferenceChange(CompactQuitFrame.self, perform: quitFrameChanged)
        .foregroundStyle(Color.white).environment(\.colorScheme, .dark)
    }
    private func compactRow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(windowTitle(window)).font(.system(size: 11))
                if window.id == model.primaryWindow?.id { Text("刘海").font(.system(size: 8)).foregroundStyle(.secondary) }
                Spacer()
                Text(window.remainingPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.system(size: 21, weight: .semibold)).monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Color.black
                    if let remaining = window.remainingPercent, remaining > 0 {
                        Capsule().fill(quotaPaint(remaining, theme: model.theme, phase: model.skinPhase))
                            .frame(width: proxy.size.width * remaining / 100)
                            .opacity(model.degraded || window.resetPending(at: model.now) ? 0.55 : 1)
                    }
                }
            }.frame(height: 3)
            Text(resetLine(window)).font(.system(size: 9)).foregroundStyle(window.resetPending(at: model.now) ? Color.orange : Color.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }.frame(minHeight: 46, alignment: .top).accessibilityElement(children: .combine)
    }
    private func resetLine(_ window: QuotaWindow) -> String {
        if window.resetPending(at: model.now) { return "等待刷新确认重置" }
        guard let reset = window.resetsAt else { return "重置时间暂不可用" }
        return reset.formatted(date: .abbreviated, time: .shortened) + " · "
            + (TimeZone.current.abbreviation(for: reset) ?? TimeZone.current.identifier) + " 重置"
    }
}

@MainActor
struct RefreshNoticeView: View {
    let notice: RefreshNotice
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(notice.window.map(windowTitle) ?? notice.title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if notice.result.kind != .readFailed, let remaining = notice.window?.remainingPercent {
                    if case .decreased(let points) = notice.change, points >= 0.01 {
                        Text(QuotaFormatting.percent(remaining + points) + " → " + QuotaFormatting.percent(remaining))
                            .font(.system(size: 21, weight: .semibold)).monospacedDigit()
                    } else {
                        Text(QuotaFormatting.percent(remaining)).font(.system(size: 21, weight: .semibold)).monospacedDigit()
                    }
                } else { Text(notice.title).font(.system(size: 13, weight: .semibold)) }
            }
            Text(notice.detail).font(.system(size: 11)).lineLimit(2)
            Text(interval).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }.foregroundStyle(Color.white).environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
    }
    private var interval: String {
        let format: (Date) -> String = { $0.formatted(date: .omitted, time: .standard) }
        let comparable: Bool
        switch notice.change { case .decreased, .unchanged: comparable = true; default: comparable = false }
        if comparable, let start = notice.result.previousFetchedAt, let end = notice.result.fetchedAt {
            return "读取区间 " + format(start) + "–" + format(end)
        }
        return "更新于 " + format(notice.receivedAt)
    }
}
#endif
