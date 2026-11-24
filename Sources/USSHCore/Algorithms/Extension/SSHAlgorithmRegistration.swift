import NIOConcurrencyHelpers
import NIOSSH

// 往 NIOSSH 的进程级注册表里登记 USSHCore 的算法。全模块只有这里调 `NIOSSHAlgorithms.register`。
//
// NIOSSH 的规则（EXTENSION-API.md）：注册表只增不减，每次密钥交换开始时取快照。客户端没设
// `hostKeyAlgorithms` 时公钥算法**登记即启用**（我们总是设）；密钥交换算法登记不等于启用，名字要进
// `keyExchangeAlgorithms` 才参与协商。
//
// 所以：
// - 现代算法（`rsa-sha2-512`、`rsa-sha2-256`、DH group16-sha512 / group14-sha256）在第一次建连接
//   （或起测试服务端）时自动登记；
// - SHA-1 的旧算法（`ssh-rsa` 签名、DH group14-sha1）只在 `registerLegacyAlgorithms()` 里登记，由
//   `allowsLegacyAlgorithms == true` 的连接触发，或者调用方明确调用；
// - 登记是进程级的，但**接受与否按连接判断**：主机密钥算法由这条连接的 `SSHAlgorithms.hostKeyAlgorithms`
//   交给 NIOSSH（`SSHClientConfiguration.hostKeyAlgorithms`，补丁 0014：报出、协商、验签都只认它），密钥交换与
//   加密方式只报这条连接配置里的，用户认证只在允许旧算法时才试 `ssh-rsa`。登记过旧算法之后，不允许旧算法的
//   连接照样拒绝 SHA-1。

extension SSHAlgorithms {
    /// 登记 USSHCore 的现代算法：RSA 主机 / 用户密钥的 `rsa-sha2-512`、`rsa-sha2-256`，
    /// 密钥交换 `diffie-hellman-group16-sha512`、`diffie-hellman-group14-sha256`。幂等、线程安全。
    ///
    /// `SSHClient.connect` 与测试服务端会自动调用。只有在连接之前就要让 NIOSSH 认识 RSA 公钥（比如用
    /// `NIOSSHPublicKey(openSSHPublicKey:)` 解析 known_hosts 里的 `ssh-rsa …` 行）时才需要自己调。
    public static func registerStandardAlgorithms() {
        _ = standardRegistration
    }

    /// ⚠️ 登记 SHA-1 的旧算法：`ssh-rsa` 签名（RSA 主机密钥与用户认证）与 `diffie-hellman-group14-sha1`。
    /// **进程级、不可撤销**。幂等、线程安全，先登记现代算法。
    ///
    /// 只为连只认 SHA-1 的老设备。登记只让 NIOSSH 认识这些算法；只有 `hostKeyAlgorithms` / `keyExchangeAlgorithms`
    /// 里有它们、且 `allowsLegacyAlgorithms == true`（例如 `.legacyCompatible`）的连接才会报出、接受。这样的连接
    /// 建立时会自动调用；测试服务端要接受 `ssh-rsa` 的用户签名也得先调用。
    public static func registerLegacyAlgorithms() {
        _ = legacyRegistration
    }

    /// 旧算法登记过没有。
    static var legacyAlgorithmsRegistered: Bool {
        legacyRegistered.withLockedValue { $0 }
    }

    // `static let` 的初始化由 Swift 保证只执行一次、线程安全。
    private static let standardRegistration: Void = {
        NIOSSHAlgorithms.register(
            publicKey: SSHRSAExtensionPublicKey.self, signature: SSHRSAExtensionSignature<SSHRSAExtensionSHA512>.self)
        NIOSSHAlgorithms.register(
            publicKey: SSHRSAExtensionPublicKey.self, signature: SSHRSAExtensionSignature<SSHRSAExtensionSHA256>.self)
        NIOSSHAlgorithms.register(
            keyExchangeAlgorithm: SSHDiffieHellmanExtensionKeyExchange<SSHDiffieHellmanGroup16SHA512>.self)
        NIOSSHAlgorithms.register(
            keyExchangeAlgorithm: SSHDiffieHellmanExtensionKeyExchange<SSHDiffieHellmanGroup14SHA256>.self)
    }()

    private static let legacyRegistration: Void = {
        registerStandardAlgorithms()
        NIOSSHAlgorithms.register(
            publicKey: SSHRSAExtensionPublicKey.self, signature: SSHRSAExtensionSignature<SSHRSAExtensionSHA1>.self)
        NIOSSHAlgorithms.register(
            keyExchangeAlgorithm: SSHDiffieHellmanExtensionKeyExchange<SSHDiffieHellmanGroup14SHA1>.self)
        legacyRegistered.withLockedValue { $0 = true }
    }()

    private static let legacyRegistered = NIOLockedValueBox(false)
}
