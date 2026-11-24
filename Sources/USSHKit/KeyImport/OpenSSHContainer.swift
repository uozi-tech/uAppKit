import Foundation

/// OpenSSH 新格式私钥容器（`-----BEGIN OPENSSH PRIVATE KEY-----`，内层 magic
/// `openssh-key-v1\0`，格式见 OpenSSH 的 PROTOCOL.key）的外层解析：走到私钥段、读掉算法标识，
/// 剩下的分量交给各算法解码器（RSA / Ed25519 / ECDSA）自己读。
///
/// 带口令的容器（`ciphername != "none"`）在这里现场解密，解密实现见
/// `OpenSSHKeyDecryption`。不给口令时不解密，只把 ciphername 原样报出去，由调用方
/// 决定报错措辞。
nonisolated enum OpenSSHContainer {

    /// 私钥段的打开结果。
    enum PrivateSection {
        /// 已就绪（未加密，或已用口令解开）。`keyType` 是私钥段里声明的算法
        /// （`ssh-rsa` / `ecdsa-sha2-nistp256` …），`body` 停在该算法的分量之前。`publicBlob` 是明文公钥段：
        /// 解码器必须核对它与私钥段推出来的公钥是同一把（`requireMatchingPublicKey`），否则文件可以「显示一个指纹、
        /// 用另一把钥匙认证」。
        case plaintext(keyType: String, body: SSHWireReader, publicBlob: [UInt8])
        /// 已加密（ciphername != "none"）且调用方没给口令。
        case encrypted(cipherName: String)
    }

    /// - Parameter passphrase: 容器带口令时用它解密；传 `nil` 表示不解密，加密容器直接
    ///   返回 `.encrypted`。
    static func openPrivateSection(text: String,
                                   passphrase: String? = nil) throws -> PrivateSection {
        let der = try extractBase64Body(text)

        // AUTH_MAGIC "openssh-key-v1\0"（16 字节，含 NUL）
        let magic = Array("openssh-key-v1\u{0}".utf8)
        guard der.count >= magic.count, Array(der.prefix(magic.count)) == magic else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "OpenSSH：缺少 magic", bundle: ModuleBundle.bundle))
        }
        var reader = SSHWireReader(Array(der.dropFirst(magic.count)))

        let cipherName = String(decoding: try reader.readString(), as: UTF8.self)
        let kdfName = String(decoding: try reader.readString(), as: UTF8.self)
        let kdfOptions = try reader.readString()
        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "OpenSSH：密钥数量非 1", bundle: ModuleBundle.bundle))
        }
        let publicBlob = try reader.readString()       // 公钥段：解码器拿它和私钥段核对
        let blob = try reader.readString()             // 私钥段：cipher=none 时即明文

        let encrypted = (cipherName != "none")
        let body: [UInt8]
        if encrypted {
            guard let passphrase else { return .encrypted(cipherName: cipherName) }
            body = try OpenSSHKeyDecryption.decryptPrivateSection(
                blob: blob, cipherName: cipherName, kdfName: kdfName,
                kdfOptions: kdfOptions, passphrase: passphrase)
        } else {
            body = blob
        }

        var priv = SSHWireReader(body)
        let check1 = try priv.readUInt32()
        let check2 = try priv.readUInt32()
        guard check1 == check2 else {
            // 解过密才走到这里的话几乎必然是口令错了：派生出的 key 不对，解出来就是
            // 随机字节，两个 checkint 还能撞上的概率是 2^-32。
            if encrypted { throw PrivateKeyImportError.incorrectPassphrase }
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "OpenSSH：checkint 不一致", bundle: ModuleBundle.bundle))
        }
        let keyType = String(decoding: try priv.readString(), as: UTF8.self)
        return .plaintext(keyType: keyType, body: priv, publicBlob: publicBlob)
    }

    /// 公钥段与私钥段推出的公钥必须是同一把（OpenSSH 读到不一致的文件也拒绝）。比的是解析后的值：类型名相同、
    /// 每个字段相同（整数去掉前导零再比），公钥段里不能有多余的字节。
    static func requireMatchingPublicKey(_ publicBlob: [UInt8], keyType: String, fields: [[UInt8]], integerFields: Set<Int> = []) throws {
        var reader = SSHWireReader(publicBlob)
        guard let type = try? reader.readString(), String(decoding: type, as: UTF8.self) == keyType else {
            throw mismatch()
        }
        for (index, expected) in fields.enumerated() {
            if integerFields.contains(index) {
                guard let value = try? reader.readMPInt(), trimmed(value) == trimmed(expected) else { throw mismatch() }
            } else {
                guard let value = try? reader.readString(), value == expected else { throw mismatch() }
            }
        }
        guard reader.isAtEnd else { throw mismatch() }
    }

    private static func trimmed(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        bytes.drop(while: { $0 == 0 })
    }

    private static func mismatch() -> PrivateKeyImportError {
        .malformedKey(reason: String(localized: "OpenSSH：公钥段与私钥段不是同一把钥匙", bundle: ModuleBundle.bundle))
    }

    /// 容器声明的密钥类型（`ssh-rsa` / `ssh-ed25519` / `ecdsa-sha2-nistp256` …），取自明文的公钥段，
    /// 所以带口令的容器不用口令也读得出来。
    static func publicKeyType(text: String) throws -> String {
        let der = try extractBase64Body(text)
        let magic = Array("openssh-key-v1\u{0}".utf8)
        guard der.count >= magic.count, Array(der.prefix(magic.count)) == magic else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "OpenSSH：缺少 magic", bundle: ModuleBundle.bundle))
        }
        var reader = SSHWireReader(Array(der.dropFirst(magic.count)))
        _ = try reader.readString()                    // ciphername
        _ = try reader.readString()                    // kdfname
        _ = try reader.readString()                    // kdfoptions
        guard try reader.readUInt32() == 1 else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "OpenSSH：密钥数量非 1", bundle: ModuleBundle.bundle))
        }
        var publicKey = SSHWireReader(try reader.readString())
        return String(decoding: try publicKey.readString(), as: UTF8.self)
    }

    /// 取 BEGIN/END 之间的 base64 并解码。
    private static func extractBase64Body(_ text: String) throws -> [UInt8] {
        let doc = try PEMDocument.parse(text)
        guard doc.label == "OPENSSH PRIVATE KEY" else {
            throw PrivateKeyImportError.malformedKey(reason: String(localized: "非 OpenSSH 私钥", bundle: ModuleBundle.bundle))
        }
        return doc.der
    }
}
