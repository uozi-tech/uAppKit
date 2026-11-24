/// USSHCore 的算法实现（RSA、DH、AES-CTR、线格式）抛出的错误。
///
/// 握手期间它们经 NIOSSH 的 `errorCaught` 冒上来，和 NIOSSH 自己的协议错误一样意味着「对端不合规或协商不成」，
/// 不是网络断了：`SSHConnectionGuard` 认这个标记，把它们归成 `SSHClientError.handshakeFailed`，
/// 而不是 `connectionClosed(.transportError)`（后者 app 会当成断网、去重连）。
package protocol SSHAlgorithmFailure: Error {}

extension SSHDiffieHellmanError: SSHAlgorithmFailure {}
extension SSHRSAError: SSHAlgorithmFailure {}
extension SSHTransportProtectionError: SSHAlgorithmFailure {}
extension SSHWireFormatError: SSHAlgorithmFailure {}
