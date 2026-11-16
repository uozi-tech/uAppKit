// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Foundation

/// 请求分发与门禁：把「app 没就绪 / 主开关 / 改动开关」这几道闸收在一处，按固定顺序执行，
/// 然后才交给 app 的 handler。
///
/// 顺序（不可调换）：
/// 1. handler 还没接上 → `Policy.notReady`（`app_not_ready`）；
/// 2. `gate == .always` 的动作（`ping`）直接交给 handler —— 主开关关着也要能探活、报开关状态；
/// 3. 主开关关着 → `Policy.controlDisabled`；
/// 4. `gate == .mutation` 且改动开关关着 → `Policy.mutationDenied`；
/// 5. 交给 handler。handler 抛 `ControlFailure` 原样回；抛别的错回 `operation_failed`。
///
/// 要看参数才能判的写门禁（例如 Redis 写命令）不在这里：handler 自己判，判不过就抛
/// `policy.mutationDenied`（或调 `requireMutationAllowed()`），码和文案与动作级门禁一致。
@MainActor
public final class ControlDispatcher<Request: ControlRequestEnvelope, Response: ControlResponseEnvelope> {
    /// 门禁失败时回什么。码与文案都已随 app 发版，由调用方原样传入，核心不归一化。
    public struct Policy: Sendable {
        public var notReady: ControlFailure
        public var controlDisabled: ControlFailure
        /// uTable：`writes_disabled`；uTerm：`mutations_disabled`。
        public var mutationDenied: ControlFailure
        /// handler 抛了非 `ControlFailure` 错误时的码。
        public var unexpectedErrorCode: String

        public init(
            notReady: ControlFailure,
            controlDisabled: ControlFailure,
            mutationDenied: ControlFailure,
            unexpectedErrorCode: String = ControlFailureCode.operationFailed
        ) {
            self.notReady = notReady
            self.controlDisabled = controlDisabled
            self.mutationDenied = mutationDenied
            self.unexpectedErrorCode = unexpectedErrorCode
        }
    }

    /// 失败发生在哪一步。app 据此决定往失败响应里加什么（例如主开关拒绝时附上 `ping` 载荷，
    /// 让客户端看得到开关状态）。
    public enum Stage: Sendable, Hashable {
        case notReady
        case enabledGate
        case mutationGate
        case handler
    }

    public typealias Handler = @MainActor (Request) async throws -> Response
    public typealias FailureResponder = @MainActor (Request, ControlFailure, Stage) async -> Response
    public typealias ErrorDescriber = @MainActor (any Error) -> String

    public let policy: Policy
    private let isEnabled: @MainActor () -> Bool
    private let allowsMutation: @MainActor () -> Bool
    private let failureResponse: FailureResponder
    private let describeError: ErrorDescriber
    private var handler: Handler?

    /// - Parameters:
    ///   - isEnabled / allowsMutation: 每条请求现读一次开关。
    ///   - failureResponse: 把失败翻成响应。默认 `Response.controlFailure(id:code:message:)`。
    ///   - describeError: 非 `ControlFailure` 错误的文案。默认 `localizedDescription`。
    public init(
        policy: Policy,
        isEnabled: @escaping @MainActor () -> Bool,
        allowsMutation: @escaping @MainActor () -> Bool,
        failureResponse: FailureResponder? = nil,
        describeError: ErrorDescriber? = nil
    ) {
        self.policy = policy
        self.isEnabled = isEnabled
        self.allowsMutation = allowsMutation
        self.failureResponse = failureResponse ?? { request, failure, _ in
            Response.controlFailure(id: request.id, code: failure.code, message: failure.message)
        }
        self.describeError = describeError ?? { $0.localizedDescription }
    }

    /// 开关取自 `ControlGateSettings`。
    public convenience init(
        policy: Policy,
        settings: ControlGateSettings,
        failureResponse: FailureResponder? = nil,
        describeError: ErrorDescriber? = nil
    ) {
        self.init(
            policy: policy,
            isEnabled: { settings.isEnabled },
            allowsMutation: { settings.allowMutations },
            failureResponse: failureResponse,
            describeError: describeError
        )
    }

    /// handler 接上了没有。没接上时一切请求回 `policy.notReady`（不是崩溃）。
    public var isReady: Bool { handler != nil }

    /// app 启动完成后接上 handler。handler 用穷举 `switch` 处理所有动作（含 `ping`）。
    public func attach(_ handler: @escaping Handler) {
        self.handler = handler
    }

    public func detach() {
        handler = nil
    }

    /// 改动开关是否打开；关着就抛 `policy.mutationDenied`。给要看参数才能判写的 handler 用。
    public func requireMutationAllowed() throws {
        guard allowsMutation() else { throw policy.mutationDenied }
    }

    public func dispatch(_ request: Request) async -> Response {
        guard let handler else {
            return await failureResponse(request, policy.notReady, .notReady)
        }
        switch request.action.gate {
        case .always:
            break
        case .enabled, .mutation:
            guard isEnabled() else {
                return await failureResponse(request, policy.controlDisabled, .enabledGate)
            }
            if request.action.gate == .mutation, !allowsMutation() {
                return await failureResponse(request, policy.mutationDenied, .mutationGate)
            }
        }
        do {
            return try await handler(request)
        } catch let failure as ControlFailure {
            return await failureResponse(request, failure, .handler)
        } catch {
            let failure = ControlFailure(code: policy.unexpectedErrorCode, message: describeError(error))
            return await failureResponse(request, failure, .handler)
        }
    }
}

#endif
