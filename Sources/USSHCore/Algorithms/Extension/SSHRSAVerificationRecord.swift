import NIOPosix

/// 「刚刚在这个线程上验过的 RSA 签名用的是哪个算法」——按连接执行算法策略用的旁路记录。
///
/// 为什么要它：NIOSSH 的公钥算法登记是进程级的，登记了 `ssh-rsa`（SHA-1）之后，**所有**客户端都会在
/// `server_host_key_algorithms` 里报它，只提供 `ssh-rsa` 主机签名的服务器就能协商成 SHA-1；而主机密钥回调
/// （`NIOSSHClientServerAuthenticationDelegate.validateHostKey`）只拿到公钥，不知道协商出的算法。
/// 于是在验签的地方记下算法，主机密钥回调里取出来，按这条连接自己的 `SSHAlgorithms` 判断要不要接受
/// （`SSHHostKeyDelegate`）。这样某条连接选用了旧算法，不会顺带让别的连接也接受 SHA-1。
///
/// 为什么按线程记：NIOSSH 客户端在同一个调用栈里、在连接的 EventLoop 线程上先验主机签名
/// （`receiveServerKeyExchangePayload` → `isValidSignature`）、紧接着调 `validateHostKey`
/// （`SSHKeyExchangeStateMachine.handle(keyExchangeReply:)`），中间不会让出线程。记录带着完整的公钥 blob，取的时候
/// 核对是同一把钥匙；别处（服务端验 userauth 签名）留下的旧记录对不上钥匙就不算数，并且会被下一次验签覆盖。
/// 取出即清除。
///
/// 服务端同理：NIOSSH 验完 userauth 签名紧接着同步调 `NIOSSHServerUserAuthenticationDelegate.requestReceived`，
/// 测试服务端借此知道客户端用的是哪个 RSA 签名算法（`SSHTestAuthAttempt.rsaSignatureAlgorithm`）。
///
/// 如果 NIOSSH 哪天改了顺序（先问回调再验签），RSA 主机密钥会因为取不到记录被拒（宁可连不上也不放过
/// SHA-1），`SSHAlgorithmPolicyTests` 与互通测试会立刻发现。
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
