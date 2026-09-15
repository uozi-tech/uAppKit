import Foundation
import Crypto

/// 解析 OpenSSH 容器中的 ECDSA 私钥（仅未加密）。容器外层见 `OpenSSHContainer`。
nonisolated enum OpenSSHECDSADecoder {

    static func decode(openSSHText: String) throws -> ParsedPrivateKey {
        switch try OpenSSHContainer.openPrivateSection(text: openSSHText) {
        case .encrypted(let cipherName):
            throw PrivateKeyImportError.unsupportedFormat(
                label: "加密的 OpenSSH ECDSA（\(cipherName)）")
        case .plaintext(let keyType, var body):
            // ecdsa-sha2-nistp256 等：curveName, Q(point), d(scalar mpint)
            guard keyType.hasPrefix("ecdsa-sha2-nistp") else {
                throw PrivateKeyImportError.unsupportedFormat(label: "OpenSSH \(keyType)")
            }
            _ = try body.readString()                  // curve name
            _ = try body.readString()                  // Q（公钥点）
            let scalar = try body.readMPInt()          // d（私钥标量）

            let curveOID: String
            switch keyType {
            case "ecdsa-sha2-nistp256": curveOID = DERKeyDecoder.OID.p256
            case "ecdsa-sha2-nistp384": curveOID = DERKeyDecoder.OID.p384
            case "ecdsa-sha2-nistp521": curveOID = DERKeyDecoder.OID.p521
            default:
                throw PrivateKeyImportError.unsupportedFormat(label: "OpenSSH \(keyType)")
            }
            return try DERKeyDecoder.makeECKey(curveOID: curveOID, scalar: scalar)
        }
    }
}
