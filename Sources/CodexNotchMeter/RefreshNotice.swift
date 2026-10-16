#if os(macOS)
import Foundation
import NotchCore

/// Presentation-only data; contains no account identity or executable path.
struct RefreshNotice: Identifiable, Equatable {
    let id: UUID
    let receivedAt: Date
    let result: QuotaUpdate
    let bucketID: String?
    let window: QuotaWindow?
    var duration: NoticeDuration = .standard
    var isEligible: Bool {
        guard let bucketID, let window else { return false }
        return result.window(bucketID: bucketID, windowID: window.id)?.hasNumericChange == true
    }

    static func make(result: QuotaUpdate, snapshot: QuotaSnapshot, preferredBucketID: String?,
                     preferredWindowID: String?, duration: NoticeDuration, receivedAt: Date = Date()) -> RefreshNotice? {
        guard let changed = result.changedWindow(preferredBucketID: preferredBucketID, preferredWindowID: preferredWindowID),
              let bucket = snapshot.buckets.first(where: { $0.id == changed.bucketID }),
              let window = bucket.windows.first(where: { $0.id == changed.windowID }) else { return nil }
        return RefreshNotice(id: UUID(), receivedAt: receivedAt, result: result, bucketID: bucket.id, window: window, duration: duration)
    }
    var change: QuotaWindowUpdate.Change? {
        guard let bucketID, let window else { return nil }
        return result.window(bucketID: bucketID, windowID: window.id)?.change
    }
    var holdDuration: TimeInterval { duration.seconds }
    var title: String {
        if result.kind == .readFailed { return "额度读取未完成" }
        if isEligible { return "额度已更新" }
        if case .unchanged = change { return "额度未变化" }
        return "额度已刷新"
    }
    var detail: String {
        if result.kind == .readFailed { return "本次读取失败，稍后重试" }
        switch change {
        case .decreased(let points): return "本次减少 " + QuotaFormatting.points(points) + " 个百分点"
        case .unchanged: return "与上次可比读取相同"
        case .updated(let reason):
            switch reason {
            case .resetPending: return "等待刷新确认重置"
            case .resetChanged: return "重置周期已更新"
            case .increased: return "剩余额度已回升"
            case .initial: return "首次读取，不计算消耗"
            case .stale, .nonMonotonic: return "读取间隔不可比，不计算消耗"
            case .identityUnavailable, .dataUnavailable:
                return isEligible ? "当前剩余额度已更新，未计算消耗差值" : "部分数据暂不可用"
            default: return "本次已更新，未计算跨状态差值"
            }
        case nil: return "本次读取完成"
        }
    }
}
#endif
