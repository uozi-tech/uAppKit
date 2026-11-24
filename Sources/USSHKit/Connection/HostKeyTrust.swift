import Crypto
import Foundation
import NIOCore
import NIOSSH
import USSHCore

nonisolated enum HostKeySerialization {
    static func serialize(
        _ key: NIOSSHPublicKey,
        host: String,
        port: Int
    ) -> SSHHostKey {
        var buffer = ByteBuffer()
        key.write(to: &buffer)
        let blob = Data(buffer.readableBytesView)
        let openSSH = String(openSSHPublicKey: key)
        let keyType = openSSH.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let digest = SHA256.hash(data: blob)
        let fingerprint = "SHA256:" + Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return SSHHostKey(
            host: host,
            port: port,
            keyType: keyType,
            keyBlob: blob,
            fingerprint: fingerprint
        )
    }
}

/// 主机密钥的信任判定：查 `HostKeyStore`，按 `SSHHostKeyPolicy` 决定接受、记住、问用户还是拒绝。
///
/// 交给 USSHCore 的是 `SSHHostKeyValidation.custom`：回调正常返回 = 接受，抛错 = 拒绝。等用户确认的时限
/// 由连接配置的 `hostKeyValidationTimeout` 管（USSHCore 在回调期间暂停握手计时，到点取消回调、以
/// `SSHClientError.hostKeyValidationTimeout` 结束连接），这里不再自己赛跑。
///
/// | 库里的结果 | strict | acceptNew | ask | insecureAcceptAll |
/// |---|---|---|---|---|
/// | trusted | 接受 | 接受 | 接受 | 接受 |
/// | unknown | 拒绝 | 记住并接受 | 问；同意则记住并接受 | 记住并接受 |
/// | mismatch | 拒绝 | 拒绝 | 问；同意则记住并接受 | 记住并接受 |
nonisolated struct HostKeyTrust: Sendable {
    /// 记进 `SSHHostKey` 的主机名与端口：连接时写的那个（跳板机的内层连接是目标机的）。
    let host: String
    let port: Int
    let store: any HostKeyStore
    let policy: SSHHostKeyPolicy
    let approver: @Sendable (SSHHostKeyChallenge) async -> Bool

    var validation: SSHHostKeyValidation {
        let trust = self
        return .custom { context in
            try await trust.validate(context.hostKey)
        }
    }

    /// 握手里等这个回调的上限：只有 `.ask` 会等人，给审批时限；其余只查一次库，给连接时限。
    static func validationTimeout(
        policy: SSHHostKeyPolicy,
        connectTimeout: Duration,
        approvalTimeout: Duration
    ) -> Duration {
        policy == .ask ? approvalTimeout : connectTimeout
    }

    func validate(_ key: NIOSSHPublicKey) async throws {
        let candidate = HostKeySerialization.serialize(key, host: host, port: port)
        let verification = try await store.verify(candidate)
        switch verification {
        case .trusted:
            return

        case .unknown:
            switch policy {
            case .strict:
                throw SSHConnectionError.hostKeyRejected(
                    String(localized: "未知主机 \(candidate.host):\(String(candidate.port))（\(candidate.fingerprint)）", bundle: ModuleBundle.bundle)
                )
            case .acceptNew, .insecureAcceptAll:
                try await store.remember(candidate)
            case .ask:
                let challenge = SSHHostKeyChallenge(hostKey: candidate, kind: .unknown)
                guard await approver(challenge) else {
                    throw SSHConnectionError.hostKeyRejected(String(localized: "用户拒绝了未知主机密钥", bundle: ModuleBundle.bundle))
                }
                // 确认得太晚（审批已超时、连接已放弃）就别再记进库。
                try Task.checkCancellation()
                try await store.remember(candidate)
            }

        case .mismatch(let previousFingerprint):
            switch policy {
            case .insecureAcceptAll:
                try await store.remember(candidate)
            case .ask:
                let challenge = SSHHostKeyChallenge(
                    hostKey: candidate,
                    kind: .mismatch,
                    previousFingerprint: previousFingerprint
                )
                guard await approver(challenge) else {
                    throw SSHConnectionError.hostKeyRejected(String(localized: "用户拒绝了变化的主机密钥", bundle: ModuleBundle.bundle))
                }
                try Task.checkCancellation()
                try await store.remember(candidate)
            case .strict, .acceptNew:
                throw SSHConnectionError.hostKeyRejected(
                    String(localized: "主机密钥已变化：原 \(previousFingerprint)，现 \(candidate.fingerprint)", bundle: ModuleBundle.bundle)
                )
            }
        }
    }
}
