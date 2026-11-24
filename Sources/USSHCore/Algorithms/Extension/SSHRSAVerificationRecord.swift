import NIOPosix

/// 「刚刚在这个线程上验过的 RSA 签名用的是哪个算法」——给测试服务端用的旁路记录。
///
/// NIOSSH 的服务端验完 userauth 签名，紧接着在同一个调用栈里同步调
/// `NIOSSHServerUserAuthenticationDelegate.requestReceived`，但只交出公钥、不交出算法名。测试服务端在委托里取出
/// 这条记录，就知道客户端用的是 `rsa-sha2-512`、`rsa-sha2-256` 还是 `ssh-rsa`（`SSHTestAuthAttempt.rsaSignatureAlgorithm`），
/// 从而能像 sshd 的 `PubkeyAcceptedAlgorithms` 那样只接受某几种。
///
/// 记录带着完整的公钥 blob，取的时候核对是同一把钥匙；取出即清除，下一次验签覆盖旧记录。客户端不用它：
/// 主机密钥算法按连接由 `SSHAlgorithms.hostKeyAlgorithms` 交给 NIOSSH 决定（NIOSSH 补丁 0014）。
package enum SSHRSAVerificationRecord {
    /// 不可变，因而 `Sendable`；每次记录换一个新实例。
    private final class Entry: Sendable {
        let algorithm: SSHRSASignatureAlgorithm
        let keyBlob: [UInt8]

        init(algorithm: SSHRSASignatureAlgorithm, keyBlob: [UInt8]) {
            self.algorithm = algorithm
            self.keyBlob = keyBlob
        }
    }

    private static let current = ThreadSpecificVariable<Entry>()

    package static func record(algorithm: SSHRSASignatureAlgorithm, keyBlob: [UInt8]) {
        current.currentValue = Entry(algorithm: algorithm, keyBlob: keyBlob)
    }

    /// 取出并清除本线程上的记录；记录的不是这把钥匙时返回 `nil`。
    package static func take(keyBlob: [UInt8]) -> SSHRSASignatureAlgorithm? {
        guard let entry = current.currentValue else { return nil }
        current.currentValue = nil
        return entry.keyBlob == keyBlob ? entry.algorithm : nil
    }
}
