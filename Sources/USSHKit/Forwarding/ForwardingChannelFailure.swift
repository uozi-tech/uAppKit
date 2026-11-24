import Foundation
import NIOSSH
import USSHCore

/// direct-tcpip 开通道失败的归类结果，供上层把「NIOSSH.NIOSSHError错误1」这类
/// 原始错误翻译成用户能看懂的话（转发被拒 / 目标不可达 / 超时）。
///
/// 归类依据：
/// - `ForwardingTimeoutError` → `.timeout`（我们自己的开通道超时保护先到 ——
///   对端 CHANNEL_OPEN 全程无响应，典型为白名单/安全组把包丢在半路）；
/// - `SSHChannelError.openRejected(SSHChannelOpenFailure)` → 按 RFC 4254 的原因码（USSHCore 已经解析好）：
///   1 = SSH_OPEN_ADMINISTRATIVELY_PROHIBITED（sshd 拒绝转发，常见 `AllowTcpForwarding no` / `PermitOpen`），
///   2 = SSH_OPEN_CONNECT_FAILED（跳板机自己连目标失败：拒绝 / 不可达 / 解析失败），
///   4 = SSH_OPEN_RESOURCE_SHORTAGE（例如超过 `MaxSessions`）；
/// - 裸的 `NIOSSHError.channelSetupRejected`（不经 USSHCore 开的通道）：取 `channelOpenFailureReasonCode`，
///   取不到再从诊断文本（`"Reason: <code> <desc>"`）解析，解析不动时退化为 `.other`。
public nonisolated struct SSHForwardingChannelFailure: Sendable {
    public enum Kind: Sendable, Equatable {
        /// 开通道请求发出后对端始终无响应（本地超时保护触发）。
        case timeout
        /// 对端 sshd 明确拒绝（administratively prohibited）。
        case administrativelyProhibited
        /// 跳板机尝试连接目标失败（connect failed：拒绝/不可达/解析失败）。
        case connectFailed
        /// 对端资源不足（resource shortage：同时开着的通道太多，例如超过 sshd 的 `MaxSessions`）。
        case resourceShortage
        /// 其他（含解析不出 reason code 的拒绝）。
        case other
    }

    public let kind: Kind
    /// 原始错误文本，供日志与排查。里面可能有服务器的原话，已经过 `SSHPeerText.sanitize`（去控制字符、截断）。
    public let detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = SSHPeerText.sanitize(detail)
    }

    public init(classifying error: Error) {
        if error is ForwardingTimeoutError {
            self.init(kind: .timeout, detail: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            return
        }
        if case SSHChannelError.openRejected(let failure) = error {
            self.init(kind: Self.kind(for: failure.reason),
                      detail: "Reason: \(failure.reasonCode) \(failure.description)")
            return
        }
        if let sshError = error as? NIOSSHError, sshError.type == .channelSetupRejected {
            let description = String(describing: sshError)
            let kind = sshError.channelOpenFailureReasonCode
                .map { Self.kind(for: SSHChannelOpenFailure.Reason(code: $0)) }
                ?? Self.rejectionKind(fromDiagnostics: description)
            self.init(kind: kind, detail: description)
            return
        }
        self.init(kind: .other, detail: String(describing: error))
    }

    static func kind(for reason: SSHChannelOpenFailure.Reason) -> Kind {
        switch reason {
        case .administrativelyProhibited: return .administrativelyProhibited
        case .connectFailed: return .connectFailed
        case .resourceShortage: return .resourceShortage
        case .unknownChannelType, .other: return .other
        }
    }

    /// 从 NIOSSHError 的诊断文本（`"… Reason: <code> <desc>"`）解析 RFC 4254
    /// reason code。解析失败返回 `.other`。
    static func rejectionKind(fromDiagnostics description: String) -> Kind {
        guard let range = description.range(of: "Reason: ") else { return .other }
        let code = description[range.upperBound...].prefix(while: \.isNumber)
        switch code {
        case "1": return .administrativelyProhibited
        case "2": return .connectFailed
        case "4": return .resourceShortage
        default: return .other
        }
    }

    /// 面向用户的失败原因（中文，与 USSHKit 既有错误文案一致）。
    public func userMessage(targetHost: String, targetPort: Int) -> String {
        let target = "\(targetHost):\(targetPort)"
        switch kind {
        case .timeout:
            return String(localized: "跳板机连不上目标 \(target)：开通道超时（多为目标的白名单/安全组未放行跳板机）", bundle: ModuleBundle.bundle)
        case .administrativelyProhibited:
            return String(localized: "跳板机拒绝端口转发（sshd 可能配置了 AllowTcpForwarding no）", bundle: ModuleBundle.bundle)
        case .connectFailed:
            return String(localized: "跳板机无法连接目标 \(target)（连接被拒绝或地址不可达）", bundle: ModuleBundle.bundle)
        case .resourceShortage:
            return String(localized: "跳板机暂时打不开到 \(target) 的通道（资源不足，可能是同时开着的通道太多）", bundle: ModuleBundle.bundle)
        case .other:
            return String(localized: "转发到 \(target) 的通道打开失败：\(detail)", bundle: ModuleBundle.bundle)
        }
    }
}
