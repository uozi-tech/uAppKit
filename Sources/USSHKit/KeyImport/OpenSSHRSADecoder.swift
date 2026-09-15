import Foundation

/// 解析 OpenSSH 容器里的 `ssh-rsa` 私钥分量（仅未加密容器）。
///
/// 存在的理由是**签名算法**，不是格式：容器里的 RSA 若交给 Citadel 解析，拿到的
/// `Insecure.RSA.PrivateKey` 只会以 `ssh-rsa`（SHA-1）签名，而 OpenSSH 8.8 起服务端
/// 默认不再接受 SHA-1 的公钥签名 —— 同一把密钥用 `ssh` 能登录、在这里却以
/// `allAuthenticationOptionsFailed` 失败。自己读出 n/e/d/p/q 就能走 `rsa-sha2-512`
/// （`RSASHA512AuthDelegate`），与 PEM 私钥同一条路。
nonisolated enum OpenSSHRSADecoder {

    /// - Returns: 未加密容器里的 RSA 分量；容器已加密时返回 `nil` —— 解密只有 Citadel
    ///   有实现，调用方据此回退到老路。
    /// - Throws: 容器结构损坏，或声明的算法不是 `ssh-rsa`。
    static func decodeComponents(openSSHText: String) throws -> RSAKeyComponents? {
        switch try OpenSSHContainer.openPrivateSection(text: openSSHText) {
        case .encrypted:
            return nil
        case .plaintext(let keyType, var body):
            guard keyType == "ssh-rsa" else {
                throw PrivateKeyImportError.unsupportedFormat(label: "OpenSSH \(keyType)")
            }
            // 私钥段分量顺序（PROTOCOL.key）：n, e, d, iqmp, p, q。
            // 注意 n 在 e 之前 —— 与公钥 blob 的 (e, n) 相反。
            let n = try body.readMPInt()
            let e = try body.readMPInt()
            let d = try body.readMPInt()
            _ = try body.readMPInt()                   // iqmp：由 p/q 可推，不取
            let p = try body.readMPInt()
            let q = try body.readMPInt()
            guard !n.isEmpty, !e.isEmpty, !d.isEmpty, !p.isEmpty, !q.isEmpty else {
                throw PrivateKeyImportError.malformedKey(reason: "OpenSSH RSA：分量为空")
            }
            return RSAKeyComponents(
                modulus: n, publicExponent: e, privateExponent: d, prime1: p, prime2: q)
        }
    }
}
