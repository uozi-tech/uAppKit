import Foundation
import Observation

/// 需审批工具的 UI 落点。`InteractiveApprovalGate` 的 presenter 把请求挂到 `pending`，面板据此在
/// 消息流末尾渲染审批卡，用户点选后 resume 挂起的工具派发。一个会话一份；工具串行派发，
/// 同一时刻最多一条待决。
@MainActor
@Observable
public final class AgentApprovalQueue {
    public struct Pending: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let request: AgentApprovalRequest
    }

    public private(set) var pending: Pending?
    @ObservationIgnored private var continuation: CheckedContinuation<ApprovalDecision, Never>?

    public init() {}

    /// 交给 `InteractiveApprovalGate(presenter:)`。队列已释放时按拒绝收场。
    public var presenter: InteractiveApprovalGate.Presenter {
        { [weak self] request in
            guard let self else { return .denied }
            return await self.present(request)
        }
    }

    /// 挂起直到用户决定。所在任务被取消（停止 / 新对话 / 会话重建）时按拒绝收场，
    /// 保证审批卡不会挂着、派发方也不会永远等下去。
    public func present(_ request: AgentApprovalRequest) async -> ApprovalDecision {
        // 串行派发下不会出现；兜底拒掉旧的，免得它的派发方挂死。
        resolve(.denied, id: nil)

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .denied)
                    return
                }
                self.continuation = continuation
                pending = Pending(id: id, request: request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(.denied, id: id) }
        }
    }

    /// 审批卡按钮回调。只对当前待决生效。
    public func decide(_ decision: ApprovalDecision, for id: UUID) {
        resolve(decision, id: id)
    }

    /// 拒掉当前待决（面板关闭等）。
    public func denyPending() {
        resolve(.denied, id: nil)
    }

    /// `id` 为 nil 时无条件结掉当前待决；否则只结掉匹配的那条
    /// （取消回调是异步投递的，届时可能已换成下一条请求）。
    private func resolve(_ decision: ApprovalDecision, id: UUID?) {
        guard let continuation else { return }
        if let id, pending?.id != id { return }
        self.continuation = nil
        pending = nil
        continuation.resume(returning: decision)
    }
}
