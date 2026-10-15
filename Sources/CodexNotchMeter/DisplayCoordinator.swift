#if os(macOS)
import AppKit
import CoreGraphics
import ColorSync
import NotchCore

@MainActor
enum NativeDisplays {
    static func snapshot() -> [DisplaySnapshot] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let builtIn = CGDisplayIsBuiltin(id) != 0
            // Public UUID is used only as a local preference key. Never log or upload it.
            let uuid = builtIn ? CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() : nil
            return DisplaySnapshot(id: id, calibrationID: uuid.map { CFUUIDCreateString(nil, $0) as String },
                name: screen.localizedName, frame: screen.frame, visibleFrame: screen.visibleFrame,
                scale: screen.backingScaleFactor, builtIn: builtIn,
                online: CGDisplayIsOnline(id) != 0, active: CGDisplayIsActive(id) != 0,
                asleep: CGDisplayIsAsleep(id) != 0, mirrored: CGDisplayIsInMirrorSet(id) != 0,
                topInset: screen.safeAreaInsets.top, auxiliaryLeft: screen.auxiliaryTopLeftArea,
                auxiliaryRight: screen.auxiliaryTopRightArea)
        }
    }
}

/// The same snapshot/planner/reconciler is exercised by native synthetic display tests.
/// Each notification re-reads capabilities; finite follow-ups never retain an old plan.
@MainActor
final class DisplayCoordinator: NSObject {
    private let model: MeterModel
    private let snapshots: () -> [DisplaySnapshot]
    private let activity: () -> DisplayActivity
    private let makeIsland: (IslandGeometry) -> IslandPanelController
    private let changed: () -> Void
    private var controllers: [UInt32: IslandPanelController] = [:]
    private var identities: [UInt32: String] = [:]
    private var timer: Timer?
    private var retryIndex = 0
    private var stopped = false
    private(set) var refreshCount = 0
    private(set) var lastRefreshAt: TimeInterval = 0
    private(set) var lastPlan: DisplayPlan?
    var islands: [IslandPanelController] { controllers.keys.sorted().compactMap { controllers[$0] } }
    var hasPendingRefresh: Bool { timer != nil }
    func island(for id: UInt32) -> IslandPanelController? { controllers[id] }
    func owns(_ window: NSWindow) -> Bool { controllers.values.contains { $0.panel === window } }

    init(model: MeterModel, snapshots: @escaping () -> [DisplaySnapshot], activity: @escaping () -> DisplayActivity,
         makeIsland: @escaping (IslandGeometry) -> IslandPanelController, changed: @escaping () -> Void = {}) {
        self.model = model; self.snapshots = snapshots; self.activity = activity
        self.makeIsland = makeIsland; self.changed = changed
    }
    /// Immediate safety reconciliation, then 150/600ms fresh rechecks for asynchronous topology changes.
    func refresh(recheck: Bool = true) {
        guard !stopped else { return }
        timer?.invalidate(); timer = nil; retryIndex = 0
        reconcile()
        if recheck && lastPlan?.shouldRecheck == true { schedule(after: 0.15) }
    }
    private func schedule(after delay: TimeInterval) {
        let next = Timer(timeInterval: delay, target: self, selector: #selector(retry(_:)), userInfo: nil, repeats: false)
        timer = next; RunLoop.main.add(next, forMode: .common)
    }
    @objc private func retry(_ sender: Timer) {
        guard !stopped, sender === timer else { return }
        timer = nil; reconcile(); retryIndex += 1
        if retryIndex < 2 && lastPlan?.shouldRecheck == true { schedule(after: 0.45) }
    }
    private func reconcile() {
        let plan = DisplayPlan.make(snapshots: snapshots(), activity: activity(), calibrations: model.horizontalCalibrations, shapes: model.shapeCalibrations, contentHeight: model.compactContentHeight)
        lastPlan = plan; refreshCount += 1; lastRefreshAt = ProcessInfo.processInfo.systemUptime
        model.configureCalibrationDisplays(plan.eligible.compactMap { target in
            target.calibrationID.map { CalibrationDisplay(id: $0, name: target.name,
                minimum: target.minimumAdjustment, maximum: target.maximumAdjustment) }
        })
        let desired = Dictionary(uniqueKeysWithValues: plan.targets.map { ($0.id, $0) })
        for id in Array(controllers.keys) {
            guard let controller = controllers[id] else { continue }
            if desired[id]?.geometry.hasSameAnchor(as: controller.geometry) != true || desired[id]?.calibrationID != identities[id] || !controller.placementIsValid {
                controller.stop(); controllers.removeValue(forKey: id); identities.removeValue(forKey: id)
            }
        }
        for target in plan.targets { controllers[target.id]?.updateGeometry(target.geometry) }
        var placementFailed = false
        for target in plan.targets where controllers[target.id] == nil {
            let controller = makeIsland(target.geometry)
            if controller.placementIsValid { controllers[target.id] = controller; identities[target.id] = target.calibrationID }
            else { controller.stop(); placementFailed = true }
        }
        let notice: String?
        if placementFailed {
            notice = "系统未提供可靠的刘海位置，已保留菜单栏入口。"
        } else if !plan.activity.permitsOverlay {
            notice = plan.activity.overlayEnabled ? "显示已暂停，恢复后会重新读取屏幕布局。" : "刘海显示已关闭，仍可使用菜单栏。"
        } else if !plan.targets.isEmpty {
            notice = nil
        } else if plan.decisions.contains(where: { $0.fallback == .mirrored }) {
            notice = "镜像显示时使用菜单栏，避免在外接屏复制刘海轮廓。"
        } else if plan.decisions.contains(where: { decision in
            guard let reason = decision.fallback else { return false }
            return [DisplayFallback.invalidGeometry, .insufficientRoom, .duplicateID].contains(reason)
        }) {
            notice = "当前屏幕未提供可靠且可容纳详情的刘海区域，已保留菜单栏入口。"
        } else {
            notice = "未检测到可用的内建刘海屏幕；无刘海、外接屏或合盖模式可使用菜单栏。"
        }
        if model.displayNotice != notice { model.displayNotice = notice }
        changed()
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; timer?.invalidate(); timer = nil
        controllers.values.forEach { $0.stop() }; controllers.removeAll(); identities.removeAll()
    }
    func verifyRetiredRefreshIsInert() -> Bool {
        guard model.demo, CommandLine.arguments.contains("--display-test") else { return false }
        let retired = timer, count = refreshCount
        stop()
        if let retired { retry(retired) }
        refresh()
        return retired != nil && refreshCount == count && timer == nil && controllers.isEmpty
    }
}
#endif
