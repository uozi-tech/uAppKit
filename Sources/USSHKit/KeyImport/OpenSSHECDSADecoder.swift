import Foundation
import Crypto

/// 解析 OpenSSH 容器中的 ECDSA 私钥（仅未加密）。容器外层见 `OpenSSHContainer`。
nonisolated enum OpenSSHECDSADecoder {

    static func decode(openSSHText: String) throws -> ParsedPrivateKey {
        switch try OpenSSHContainer.openPrivateSection(text: openSSHText) {
        case .encrypted(let cipherName):
            throw PrivateKeyImportError.unsupportedFormat(
                label: String(localized: "加密的 OpenSSH ECDSA（\(cipherName)）", bundle: ModuleBundle.bundle))
        case .plaintext(let keyType, var body, let publicBlob):
            // ecdsa-sha2-nistp256 等：curveName, Q(point), d(scalar mpint)
            guard keyType.hasPrefix("ecdsa-sha2-nistp") else {
                throw PrivateKeyImportError.unsupportedFormat(label: "OpenSSH \(keyType)")
            }
            let curve = try body.readString()          // curve name
            let point = try body.readString()          // Q（公钥点）
            let scalar = try body.readMPInt()          // d（私钥标量）

            let curveOID: String
            switch keyType {
            case "ecdsa-sha2-nistp256": curveOID = DERKeyDecoder.OID.p256
            case "ecdsa-sha2-nistp384": curveOID = DERKeyDecoder.OID.p384
            case "ecdsa-sha2-nistp521": curveOID = DERKeyDecoder.OID.p521
            default:
                throw PrivateKeyImportError.unsupportedFormat(label: "OpenSSH \(keyType)")
            }
            let key = try DERKeyDecoder.makeECKey(curveOID: curveOID, scalar: scalar)
            // 标量推出的公钥点、私钥段里记的点、公钥段里的点，三者必须一致。
            let derived: [UInt8]
            switch key {
            case .p256(let k): derived = [UInt8](k.publicKey.x963Representation)
            case .p384(let k): derived = [UInt8](k.publicKey.x963Representation)
            case .p521(let k): derived = [UInt8](k.publicKey.x963Representation)
            default: throw PrivateKeyImportError.unsupportedFormat(label: "OpenSSH \(keyType)")
            }
            guard derived == point else {
                throw PrivateKeyImportError.malformedKey(
                    reason: String(localized: "OpenSSH：公钥段与私钥段不是同一把钥匙", bundle: ModuleBundle.bundle))
            }
            try OpenSSHContainer.requireMatchingPublicKey(publicBlob, keyType: keyType, fields: [curve, derived])
            return key
        }
    }
}
