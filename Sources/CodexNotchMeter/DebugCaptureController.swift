#if os(macOS)
import AppKit
import Combine
import UniformTypeIdentifiers
import NotchCore

/// User-controlled, memory-only field capture. Never restored from defaults,
/// never writes automatically, and owns no timer while disabled/stopped.
@MainActor
final class DebugCaptureController: NSObject, ObservableObject {
    let recorder: DebugCapture
    @Published private(set) var isRecording = false
    @Published private(set) var hasCapture = false
    @Published private(set) var status = "未录制。默认关闭；不自动上传。"
    var stateChanged: (() -> Void)?
    private var deadline: Timer?
    var hasScheduledDeadline: Bool { deadline != nil }

    init(recorder: DebugCapture = DebugCapture()) {
        self.recorder = recorder
        super.init()
        recorder.didStop = { [weak self] in
            // Every app access to this recorder is main-actor isolated. Keep
            // state/deadline in sync even if an input reaches expiry first.
            MainActor.assumeIsolated { self?.recordingStopped() }
        }
    }
    private func recordingStopped() {
        deadline?.invalidate(); deadline = nil
        isRecording = false
        status = recorder.stopReason == .durationLimit
            ? "已达 5 分钟上限，录制已停止。日志仍在内存，可手动导出。"
            : "录制已停止。日志仍在内存，可手动导出。"
        stateChanged?()
    }
    func start() {
        guard !isRecording else { return }
        deadline?.invalidate()
        recorder.start(metadata: .init(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))
        isRecording = true; hasCapture = true
        status = "正在录制，最多 5 分钟 / 2 MiB。请关闭设置和菜单后复现。"
        let timer = Timer(timeInterval: recorder.durationLimit, target: self,
                          selector: #selector(durationReached(_:)), userInfo: nil, repeats: false)
        deadline = timer; RunLoop.main.add(timer, forMode: .common)
        stateChanged?()
    }
    @objc private func durationReached(_ sender: Timer) {
        guard sender === deadline else { return }
        stop(reason: .durationLimit)
    }
    func stop(reason: DebugCapture.StopReason = .manual) {
        deadline?.invalidate(); deadline = nil
        guard isRecording else { return }
        recorder.stop(reason: reason)
    }
    func stopAndExport() {
        stop()
        guard hasCapture else { return }
        let save = NSSavePanel()
        save.title = "导出抖动诊断日志"
        save.message = "仅保存到你选择的位置，不自动发送。请检查后自行分享。取消不会丢失本次日志。"
        save.nameFieldStringValue = "CodexNotchMeter-debug.jsonl"
        save.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .data]
        save.canCreateDirectories = true
        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            try recorder.export { try $0.write(to: url, options: .atomic) }
            status = "已导出，可检查后手动发送。内存中的本次日志仍保留。"
        } catch {
            // Do not surface errors that may include private file paths.
            status = "导出失败，本次日志仍保留。请检查目标文件夹权限和磁盘空间后重试。"
            let alert = NSAlert()
            alert.messageText = "无法导出诊断日志"
            alert.informativeText = status
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}
#endif
