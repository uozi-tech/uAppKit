import Foundation

/// OpenSSH 新格式私钥容器（`-----BEGIN OPENSSH PRIVATE KEY-----`，内层 magic
/// `openssh-key-v1\0`）的外层解析：走到私钥段、读掉算法标识，剩下的分量交给各算法
/// 解码器自己读。
///
/// 加密容器不在这里解 —— 解密要 bcrypt_pbkdf + aes-ctr，实现只在 Citadel 内部（C
/// target `CCitadelBcrypt` 不是它的 product，包外够不着）。所以这里只把 ciphername
/// 原样报出去，由调用方决定报错还是回退。
nonisolated enum OpenSSHContainer {

    /// 私钥段的打开结果。
    enum PrivateSection {
        /// 未加密。`keyType` 是私钥段里声明的算法（`ssh-rsa` / `ecdsa-sha2-nistp256` …），
        /// `body` 停在该算法的分量之前。
        case plaintext(keyType: String, body: SSHWireReader)
        /// 已加密（ciphername != "none"）。
        case encrypted(cipherName: String)
    }

    static func openPrivateSection(text: String) throws -> PrivateSection {
        let der = try extractBase64Body(text)

        // AUTH_MAGIC "openssh-key-v1\0"（16 字节，含 NUL）
        let magic = Array("openssh-key-v1\u{0}".utf8)
        guard der.count >= magic.count, Array(der.prefix(magic.count)) == magic else {
            throw PrivateKeyImportError.malformedKey(reason: "OpenSSH：缺少 magic")
        }
        var reader = SSHWireReader(Array(der.dropFirst(magic.count)))

        let cipherName = String(decoding: try reader.readString(), as: UTF8.self)
        guard cipherName == "none" else { return .encrypted(cipherName: cipherName) }
        _ = try reader.readString()                    // kdfname
        _ = try reader.readString()                    // kdfoptions
        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else {
            throw PrivateKeyImportError.malformedKey(reason: "OpenSSH：密钥数量非 1")
        }
        _ = try reader.readString()                    // 公钥段（跳过）

        // 私钥段（cipher=none 时即明文）
        var priv = SSHWireReader(try reader.readString())
        let check1 = try priv.readUInt32()
        let check2 = try priv.readUInt32()
        guard check1 == check2 else {
            throw PrivateKeyImportError.malformedKey(reason: "OpenSSH：checkint 不一致")
        }
        let keyType = String(decoding: try priv.readString(), as: UTF8.self)
        return .plaintext(keyType: keyType, body: priv)
    }

    /// 取 BEGIN/END 之间的 base64 并解码。
    private static func extractBase64Body(_ text: String) throws -> [UInt8] {
        let doc = try PEMDocument.parse(text)
        guard doc.label == "OPENSSH PRIVATE KEY" else {
            throw PrivateKeyImportError.malformedKey(reason: "非 OpenSSH 私钥")
        }
        return doc.der
    }
}
