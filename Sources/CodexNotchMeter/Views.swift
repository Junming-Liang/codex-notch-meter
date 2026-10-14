#if os(macOS)
import SwiftUI
import NotchCore

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

func quotaColor(_ remaining: Double?) -> Color {
    guard let remaining else { return .gray }
    if remaining <= 10 { return .red }
    if remaining <= 25 { return .orange }
    return .mint
}

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
        let dim = model.degraded || (window?.resetPending(at: model.now) ?? false)
        ZStack {
            NotchRail(left: left).stroke(Color.black.opacity(0.88), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            NotchRail(left: left).stroke(Color.white.opacity(0.24), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            if let remaining {
                NotchRail(left: left).trim(from: 0, to: remaining / 100)
                    .stroke(quotaColor(remaining).opacity(dim ? 0.4 : 1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            } else {
                NotchRail(left: left).stroke(Color.gray.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [3, 5]))
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window?.label ?? "Quota unavailable")
        .accessibilityValue(remaining.map { "\(Int($0.rounded())) percent remaining" } ?? "Unknown")
    }
}

struct DetailView: View {
    @ObservedObject var model: MeterModel
    let hovered: (Bool) -> Void
    let refresh: () -> Void
    let settings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(.mint)
                Text("Codex Notch Meter").font(.headline)
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
            }
            Text(model.status).font(.caption).foregroundStyle(model.error == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let snapshot = model.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(snapshot.buckets) { bucket in
                            VStack(alignment: .leading, spacing: 10) {
                                if snapshot.buckets.count > 1 { Text(bucket.name).font(.subheadline.bold()) }
                                ForEach(bucket.windows) { window in QuotaRow(window: window, now: model.now, degraded: model.degraded) }
                                if bucket.windows.isEmpty { Text("Quota unavailable").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }.frame(maxHeight: 340)
                Text("Checked \(snapshot.fetchedAt.formatted(date: .omitted, time: .standard))\(model.stale ? " · stale" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Refresh", action: refresh).disabled(model.refreshing || model.demo)
                Spacer()
                Button("Settings…", action: settings)
            }.controlSize(.small)
        }
        .padding(18)
        .frame(width: 340)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)))
        .onHover(perform: hovered)
    }
}

struct QuotaRow: View {
    let window: QuotaWindow
    let now: Date
    let degraded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.label).font(.subheadline)
                Spacer()
                Text(window.remainingPercent.map { String(format: "%.0f%% left", $0) } ?? "Unknown")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
            }
            if let remaining = window.remainingPercent {
                ProgressView(value: remaining, total: 100).tint(quotaColor(remaining))
                    .opacity(degraded || window.resetPending(at: now) ? 0.45 : 1)
            } else { Capsule().fill(.gray.opacity(0.3)).frame(height: 4) }
            Text(window.countdown(at: now)).font(.caption).foregroundStyle(.secondary)
            if let reset = window.resetsAt {
                Text(reset.formatted(date: .abbreviated, time: .standard) + " · " + (TimeZone.current.abbreviation(for: reset) ?? TimeZone.current.identifier))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: MeterModel
    let chooseExecutable: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Codex Notch Meter").font(.title2.bold())
            Text("A quiet, read-only view of your remaining Codex allowance.")
                .foregroundStyle(.secondary)
            Toggle("Show progress rails around the notch", isOn: $model.overlayEnabled)
            Text("On displays without a notch, quotas stay in the menu bar. Hover the rails or click the menu bar item for details.")
                .font(.caption).foregroundStyle(.secondary)
            if let buckets = model.snapshot?.buckets, buckets.count > 1 {
                Picker("Notch quota group", selection: $model.preferredBucket) {
                    ForEach(buckets) { bucket in Text(bucket.name).tag(bucket.id) }
                }
            }
            Divider()
            Text("Codex executable").font(.headline)
            Text(model.executablePath.isEmpty ? "Automatic: PATH / Homebrew" : model.executablePath)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(3)
            HStack {
                Button("Choose installed Codex…", action: chooseExecutable)
                Button("Use automatic discovery") { model.setExecutable("") }
            }
            Text("Choose only the official Codex CLI you installed and trust. Sign in using Codex itself. This app never asks for your password or reads credential files.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("No model prompts. No conversation history. No telemetry. No Accessibility or Screen Recording permissions. Does not launch at login.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Experimental account protocol. Missing or expired data is never treated as a full allowance.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refresh now") { model.refresh() }.disabled(model.refreshing || model.demo)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }.padding(24).frame(width: 460)
    }
}
#endif
