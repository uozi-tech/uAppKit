import Foundation
import NIOCore
import NIOSSH
import USSHCore

// SSH-STACK-TODO(core): 这个文件整个是临时垫片。Track E 正在给 USSHCore 加三样东西：
// `SSHAuthenticationMethod.rsaPrivateKey(SSHRSAPrivateKey)`（先试 rsa-sha2-512、再试 -256）、
// `SSHClient.openSFTP(configuration:)`、`SSHAlgorithms` 的 `.standard` / `.legacyCompatible` / `.builtInOnly`。
// 合进来之后删掉本文件，调用处换成真接口（每处都只调这里的一个名字）。

/// USSHKit 对 USSHCore 还没有的三样东西的临时实现。
@usableFromInline
nonisolated enum CoreShims {
    /// USSHKit 默认的算法集：NIOSSH 自带的那些（今天的行为）。换成 `SSHAlgorithms.builtInOnly`。
    @usableFromInline
    static let defaultAlgorithms = SSHAlgorithms()

    /// RSA 用户私钥的认证方式：`rsa-sha2-512`，被拒再 `rsa-sha2-256`（不发 SHA-1 的 `ssh-rsa`）。
    /// 换成 `[.rsaPrivateKey(key)]`。
    static func rsaAuthenticationMethods(_ key: SSHRSAPrivateKey) -> [SSHAuthenticationMethod] {
        [
            .privateKey(NIOSSHPrivateKey(custom: ShimRSAPrivateKey<ShimRSASHA512>(key: key))),
            .privateKey(NIOSSHPrivateKey(custom: ShimRSAPrivateKey<ShimRSASHA256>(key: key))),
        ]
    }

    /// 开 SFTP 子系统通道并完成 SFTP 握手。换成 `client.openSFTP()`。
    static func openSFTP(on client: SSHClient) async throws -> SFTPClient {
        let channel = try await client.openSubsystemChannel("sftp")
        return try await SFTPClient.start(on: channel)
    }
}

// MARK: - RSA 用户私钥接到 NIOSSH 的密钥扩展接口上

// 客户端签名、写出公钥不需要登记（NIOSSH：写出不查注册表）；只有校验的一方（服务端，测试里是进程内的
// `SSHTestServer`）要 `NIOSSHAlgorithms.register(publicKey:signature:)` 才认得出来。所以 USSHKit 自己
// 不登记，测试里登记（见 `USSHKitTests/Support`）。

protocol ShimRSAHash: Sendable {
    static var algorithm: SSHRSASignatureAlgorithm { get }
}

enum ShimRSASHA512: ShimRSAHash {
    static let algorithm = SSHRSASignatureAlgorithm.rsaSHA2_512
}

enum ShimRSASHA256: ShimRSAHash {
    static let algorithm = SSHRSASignatureAlgorithm.rsaSHA2_256
}

/// `ssh-rsa` 格式的公钥（RFC 8332：公钥 blob 的类型名永远是 `ssh-rsa`，签名算法另算）。
struct ShimRSAPublicKey: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = SSHRSAPublicKey.keyType

    let key: SSHRSAPublicKey

    var rawRepresentation: Data {
        var buffer = ByteBuffer()
        key.writeBody(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        switch signature {
        case let signature as ShimRSASignature<ShimRSASHA512>:
            return key.isValidSignature(signature.signature, for: data, algorithm: .rsaSHA2_512)
        case let signature as ShimRSASignature<ShimRSASHA256>:
            return key.isValidSignature(signature.signature, for: data, algorithm: .rsaSHA2_256)
        default:
            return false
        }
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        key.writeBody(to: &buffer)
    }

    static func read(from buffer: inout ByteBuffer) throws -> ShimRSAPublicKey {
        ShimRSAPublicKey(key: try SSHRSAPublicKey(readingBodyFrom: &buffer))
    }
}

struct ShimRSASignature<Hash: ShimRSAHash>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Hash.algorithm.name }

    let signature: SSHRSASignature

    var rawRepresentation: Data { Data(signature.bytes) }

    func write(to buffer: inout ByteBuffer) -> Int {
        signature.writeBody(to: &buffer)
    }

    static func read(from buffer: inout ByteBuffer) throws -> ShimRSASignature<Hash> {
        ShimRSASignature(signature: try SSHRSASignature(algorithm: Hash.algorithm, readingBodyFrom: &buffer))
    }
}

struct ShimRSAPrivateKey<Hash: ShimRSAHash>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { Hash.algorithm.name }

    let key: SSHRSAPrivateKey

    var publicKey: NIOSSHPublicKeyProtocol { ShimRSAPublicKey(key: key.publicKey) }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        ShimRSASignature<Hash>(signature: try key.signature(for: data, algorithm: Hash.algorithm))
    }
}
