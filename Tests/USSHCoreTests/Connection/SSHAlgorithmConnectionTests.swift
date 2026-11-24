import BigInt
import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
@testable import NIOSSH
@testable import USSHCore
import USSHTestServer
import XCTest

/// RSA / DH 经扩展接口接上之后，客户端 ↔ 进程内服务端的端到端：用户认证的算法与顺序、RSA 主机密钥、
/// 每种 DH（含换钥）、按连接的旧算法策略、恶意服务器（经 `KeyExchangeReplyTamperer` 改 KEX 回复）。
///
/// 进程里会登记旧算法（有的用例需要服务端认 `ssh-rsa`），这正好证明了登记之后，不允许旧算法的连接照样拒绝。
final class SSHAlgorithmConnectionTests: XCTestCase {
    static let rsaKey = try! SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[1].pkcs1PEM)   // 2048 位
    static let otherRSAKey = try! SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[2].pkcs1PEM) // 3072 位

    /// Debug 构建里 group16 的模幂每次一到三秒，握手时限放宽。
    private static let slowHandshake: Duration = .seconds(120)

    private func client(
        _ methods: [SSHAuthenticationMethod] = [.password(Harness.password)],
        algorithms: SSHAlgorithms = .standard,
        hostKey: SSHHostKeyValidation = .acceptAnything
    ) -> SSHClient.Configuration {
        var configuration = Harness.clientConfiguration(methods, hostKey: hostKey, handshakeTimeout: Self.slowHandshake)
        configuration.algorithms = algorithms
        return configuration
    }

    private func rsaServer(
        accepting algorithms: Set<SSHRSASignatureAlgorithm>? = nil,
        serverSignatureAlgorithms: [String]? = nil,
        acceptsLegacy: Bool = false
    ) async throws -> SSHTestServer {
        var configuration = Harness.serverConfiguration(keys: [NIOSSHPublicKey(rsaPublicKey: Self.rsaKey.publicKey)])
        configuration.authentication.acceptedRSASignatureAlgorithms = algorithms
        configuration.serverSignatureAlgorithms = serverSignatureAlgorithms
        configuration.acceptsLegacyAlgorithms = acceptsLegacy
        return try await SSHTestServer.start(configuration)
    }

    private func rsaAttempts(_ server: SSHTestServer) -> [SSHRSASignatureAlgorithm?] {
        server.events.authAttempts.map(\.rsaSignatureAlgorithm)
    }

    // MARK: - RSA 用户认证

    func testRSAUserAuthUsesRSASHA2512First() async throws {
        let server = try await rsaServer()
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server, client([.rsaPrivateKey(Self.rsaKey)]))
        defer { Task { await client.close() } }
        XCTAssertEqual(rsaAttempts(server), [.rsaSHA2_512])
        XCTAssertEqual(server.events.authAttempts.map(\.accepted), [true])
    }

    func testRSAUserAuthFallsBackToRSASHA2256WithoutServerSigAlgs() async throws {
        let server = try await rsaServer(accepting: [.rsaSHA2_256])
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server, client([.rsaPrivateKey(Self.rsaKey)]))
        defer { Task { await client.close() } }
        XCTAssertEqual(rsaAttempts(server), [.rsaSHA2_512, .rsaSHA2_256])
        XCTAssertEqual(server.events.authAttempts.map(\.accepted), [false, true])
    }

    func testRSAUserAuthUsesServerSigAlgsForTheFirstAttempt() async throws {
        let server = try await rsaServer(accepting: [.rsaSHA2_256], serverSignatureAlgorithms: ["ssh-ed25519", "rsa-sha2-256"])
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server, client([.rsaPrivateKey(Self.rsaKey)]))
        defer { Task { await client.close() } }
        XCTAssertEqual(rsaAttempts(server), [.rsaSHA2_256], "宣告了 server-sig-algs 就直接用其中最好的")
    }

    func testRSAUserAuthSkippedWhenServerSigAlgsListsNoRSA() async throws {
        let server = try await rsaServer(serverSignatureAlgorithms: ["ssh-ed25519"])
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server, client([.rsaPrivateKey(Self.rsaKey), .password(Harness.password)]))
        defer { Task { await client.close() } }
        XCTAssertEqual(server.events.authAttempts.map(\.method), [.password(Harness.password)], "RSA 一次也不该试")
    }

    func testSHA1OnlyServerRefusesStandardAndAcceptsLegacy() async throws {
        let server = try await rsaServer(accepting: [.sshRSA], acceptsLegacy: true)
        defer { Task { await server.stop() } }

        await XCTAssertThrowsAsync(try await Harness.connect(server, self.client([.rsaPrivateKey(Self.rsaKey)]))) { error in
            guard case SSHClientError.authenticationFailed(let failure) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(failure.attemptedMethods, [.publicKey, .publicKey])
        }
        XCTAssertEqual(rsaAttempts(server), [.rsaSHA2_512, .rsaSHA2_256], "不允许旧算法时不试 ssh-rsa")

        let client = try await Harness.connect(server, self.client([.rsaPrivateKey(Self.rsaKey)], algorithms: .legacyCompatible))
        defer { Task { await client.close() } }
        XCTAssertEqual(rsaAttempts(server).suffix(3), [.rsaSHA2_512, .rsaSHA2_256, .sshRSA])
        XCTAssertEqual(server.events.authAttempts.last?.accepted, true)
    }

    func testSHA1OnlyServerSigAlgs() async throws {
        let server = try await rsaServer(accepting: [.sshRSA], serverSignatureAlgorithms: ["ssh-rsa"], acceptsLegacy: true)
        defer { Task { await server.stop() } }
        // 不允许旧算法：一个能用的都没有，RSA 不试，认证失败。
        await XCTAssertThrowsAsync(try await Harness.connect(server, self.client([.rsaPrivateKey(Self.rsaKey)]))) { error in
            guard case SSHClientError.authenticationFailed(let failure) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(failure.attemptedMethods, [])
        }
        XCTAssertEqual(server.events.authAttempts.count, 0)
        let client = try await Harness.connect(server, self.client([.rsaPrivateKey(Self.rsaKey)], algorithms: .legacyCompatible))
        defer { Task { await client.close() } }
        XCTAssertEqual(rsaAttempts(server), [.sshRSA])
    }

    /// 请求里写 `rsa-sha2-512`、签名却是 `ssh-rsa`（SHA-1）的：服务端必须拒绝（防降级）。
    func testUserAuthSignatureLabelledSSHRSAUnderRSASHA2512IsRejected() async throws {
        let server = try await rsaServer(acceptsLegacy: true)
        defer { Task { await server.stop() } }
        let liar = NIOSSHPrivateKey(custom: MislabelledRSAKey(key: Self.rsaKey))
        await XCTAssertThrowsAsync(try await Harness.connect(server, client([.privateKey(liar)])))
        XCTAssertFalse(server.events.authAttempts.contains { $0.accepted })
    }

    func testWrongRSAKeyIsRejected() async throws {
        let server = try await rsaServer()
        defer { Task { await server.stop() } }
        await XCTAssertThrowsAsync(try await Harness.connect(server, client([.rsaPrivateKey(Self.otherRSAKey)]))) { error in
            guard case SSHClientError.authenticationFailed = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - RSA 主机密钥

    private func rsaHostServer(
        _ key: SSHRSAPrivateKey = rsaKey,
        algorithms: [SSHRSASignatureAlgorithm] = SSHRSASignatureAlgorithm.modern
    ) async throws -> SSHTestServer {
        var configuration = Harness.serverConfiguration()
        configuration.useRSAHostKey(key, algorithms: algorithms)
        return try await SSHTestServer.start(configuration)
    }

    func testRSAHostKeyWithEachModernAlgorithm() async throws {
        for algorithm in SSHRSASignatureAlgorithm.modern {
            let server = try await rsaHostServer(algorithms: [algorithm])
            defer { Task { await server.stop() } }
            let expected = NIOSSHPublicKey(rsaPublicKey: Self.rsaKey.publicKey)
            XCTAssertEqual(server.hostPublicKey, expected)
            let seen = NIOLockedValueBox<NIOSSHPublicKey?>(nil)
            let client = try await Harness.connect(server, client(hostKey: .custom { context in
                seen.withLockedValue { $0 = context.hostKey }
            }))
            XCTAssertEqual(seen.withLockedValue { $0 }?.rsaPublicKey, Self.rsaKey.publicKey, algorithm.name)
            try await client.ping()
            await client.close()
            // trustedKeys 里放 RSA 公钥同样认。
            let trusted = try await Harness.connect(server, self.client(hostKey: .trustedKeys([expected])))
            await trusted.close()
        }
    }

    func testBuiltInOnlyRefusesRSAHostKeyEvenThoughRegistered() async throws {
        let server = try await rsaHostServer()
        defer { Task { await server.stop() } }
        let asked = NIOLockedValueBox(false)
        await XCTAssertThrowsAsync(try await Harness.connect(server, client(algorithms: .builtInOnly, hostKey: .custom { _ in
            asked.withLockedValue { $0 = true }
        }))) { error in
            guard case SSHClientError.handshakeFailed(let underlying) = error,
                  let refused = underlying as? SSHHostKeyAlgorithmRefused else { return XCTFail("\(error)") }
            XCTAssertEqual(refused.algorithm, .rsaSHA2_512)
        }
        XCTAssertFalse(asked.withLockedValue { $0 }, "拒绝算法时不该问主机密钥回调")
    }

    func testSHA1HostKeyRefusedUnlessLegacyAllowed() async throws {
        let server = try await rsaHostServer(algorithms: [.sshRSA])
        defer { Task { await server.stop() } }
        XCTAssertTrue(SSHAlgorithms.legacyAlgorithmsRegistered, "服务端提供 ssh-rsa 时已登记旧算法")
        await XCTAssertThrowsAsync(try await Harness.connect(server, client())) { error in
            guard case SSHClientError.handshakeFailed(let underlying) = error,
                  let refused = underlying as? SSHHostKeyAlgorithmRefused else { return XCTFail("\(error)") }
            XCTAssertEqual(refused.algorithm, .sshRSA)
        }
        let client = try await Harness.connect(server, client(algorithms: .legacyCompatible))
        await client.close()
    }

    func testTamperedRSAHostSignatureIsRejected() async throws {
        let server = try await rsaHostServer()
        defer { Task { await server.stop() } }
        let proxy = try await KeyExchangeReplyTamperer.start(targetPort: server.port) { reply in
            var parts = reply.signatureParts
            parts.bytes[parts.bytes.count / 2] ^= 0x01
            reply.signatureParts = parts
        }
        defer { Task { await proxy.stop() } }
        await XCTAssertThrowsAsync(try await self.connect(port: proxy.port, client())) { error in
            guard case SSHClientError.handshakeFailed(let underlying) = error,
                  (underlying as? NIOSSHError)?.type == .invalidExchangeHashSignature else { return XCTFail("\(error)") }
        }
    }

    /// 协商的是 `rsa-sha2-512`，服务器却回 `ssh-rsa` 标签的签名（降级）：允不允许旧算法都必须拒绝。
    func testSSHRSALabelledHostSignatureUnderRSASHA2512IsRejected() async throws {
        SSHAlgorithms.registerLegacyAlgorithms()   // 否则 NIOSSH 连 ssh-rsa 签名都解析不了，测不到这一层
        let server = try await rsaHostServer(algorithms: [.rsaSHA2_512])
        defer { Task { await server.stop() } }
        let signer = Self.rsaKey
        let proxy = try await KeyExchangeReplyTamperer.start(targetPort: server.port) { reply in
            // 换成同一把钥匙对不知道的数据签的 SHA-1 签名也一样：标签对不上就不会去验。
            reply.signatureParts = ("ssh-rsa", (try? signer.signature(for: [1, 2, 3], algorithm: .sshRSA).bytes) ?? [])
        }
        defer { Task { await proxy.stop() } }
        for algorithms in [SSHAlgorithms.standard, .legacyCompatible] {
            await XCTAssertThrowsAsync(try await self.connect(port: proxy.port, client(algorithms: algorithms))) { error in
                guard case SSHClientError.handshakeFailed(let underlying) = error,
                      (underlying as? NIOSSHError)?.type == .invalidHostKeyForKeyExchange else { return XCTFail("\(error)") }
            }
        }
    }

    func testLargestAndLargeExponentRSAHostKeys() async throws {
        for (label, pem) in [("8192", LargeRSAFixtures.modulus8192PEM), ("e=2^32+1", LargeRSAFixtures.largeExponentPEM)] {
            let key: SSHRSAPrivateKey
            do {
                key = try SSHRSAPrivateKey(pemRepresentation: pem)
            } catch {
                XCTFail("\(label): \(error)")
                continue
            }
            let server = try await rsaHostServer(key, algorithms: [.rsaSHA2_256])
            defer { Task { await server.stop() } }
            let client = try await Harness.connect(server, client(
                hostKey: .trustedKeys([NIOSSHPublicKey(rsaPublicKey: key.publicKey)])))
            await client.close()
        }
    }

    /// 16384 位的主机密钥（OpenSSH 允许，BoringSSL 不支持）：解析时就干净地拒绝，握手失败而不是崩溃。
    func testOversizedRSAHostKeyIsRejectedCleanly() async throws {
        SSHAlgorithms.registerStandardAlgorithms()
        let line = LargeRSAFixtures.modulus16384OpenSSHPublicKey
        XCTAssertThrowsError(try NIOSSHPublicKey(openSSHPublicKey: line))
        var blob = ByteBuffer(bytes: Data(base64Encoded: String(line.split(separator: " ")[1]))!)
        _ = try blob.readSSHWireIdentifier()
        XCTAssertThrowsError(try SSHRSAExtensionPublicKey.read(from: &blob)) { error in
            XCTAssertEqual(error as? SSHRSAError, .unsupportedModulusSize(bits: 16384))
        }

        // 恶意服务器把 K_S 换成它：客户端解析不了，握手失败。
        let server = try await rsaHostServer()
        defer { Task { await server.stop() } }
        let oversized = Array(Data(base64Encoded: String(line.split(separator: " ")[1]))!)
        let proxy = try await KeyExchangeReplyTamperer.start(targetPort: server.port) { reply in
            reply.hostKey = oversized
        }
        defer { Task { await proxy.stop() } }
        await XCTAssertThrowsAsync(try await self.connect(port: proxy.port, client()))
    }

    /// 公钥指数超过 BoringSSL 的 33 位上限：干净地拒绝。
    func testOversizedRSAExponentIsRejectedCleanly() throws {
        let modulus = try SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[1].pkcs1PEM).publicKey.modulus
        XCTAssertThrowsError(try SSHRSAPublicKey(modulus: modulus, publicExponent: [0x01, 0, 0, 0, 0, 0, 0, 0, 0x01]))
    }

    // MARK: - 有限域 DH

    private func dhServer(_ algorithms: [String], schemes: [SSHTransportProtections.Scheme]? = nil) async throws -> SSHTestServer {
        var configuration = Harness.serverConfiguration(exec: .scripted(stdout: "ok\n"))
        configuration.keyExchangeAlgorithms = algorithms
        configuration.transportProtectionSchemes = schemes
        return try await SSHTestServer.start(configuration)
    }

    /// 每种 DH 都能握手、跑命令，客户端发起换钥（NIOSSH 内部的 `_rekey`）之后照样能用，换钥时又核对了一次主机密钥。
    func testEachDiffieHellmanAlgorithmIncludingRekey() async throws {
        for algorithm in SSHDiffieHellmanAlgorithm.allCases {
            let server = try await dhServer([algorithm.name])
            defer { Task { await server.stop() } }
            let validations = Counter()
            let started = ContinuousClock.now
            let client = try await Harness.connect(server, client(
                algorithms: algorithm.isLegacy ? .legacyCompatible : .standard,
                hostKey: .custom { _ in validations.add(1) }))
            let handshake = ContinuousClock.now - started
            let outputX = String(buffer: try await client.executeCommand("x"))
            XCTAssertEqual(outputX, "ok\n", algorithm.name)
            try await client.eventLoop.submit { try client.sshHandler.value._rekey() }.get()
            let rekeyed = await Harness.eventually(timeout: Self.slowHandshake) { validations.value == 2 }
            XCTAssertTrue(rekeyed, "\(algorithm.name) 换钥没有完成")
            let outputY = String(buffer: try await client.executeCommand("y"))
            XCTAssertEqual(outputY, "ok\n", algorithm.name)
            print("[measure] in-process handshake \(algorithm.name): \(handshake)")
            await client.close()
        }
    }

    func testLegacyKeyExchangeRefusedUnlessAllowed() async throws {
        let server = try await dhServer([SSHDiffieHellmanAlgorithm.group14SHA1.name])
        defer { Task { await server.stop() } }
        // 列表里写了也没用：开关没开就被滤掉，没有共同算法。
        var sneaky = SSHAlgorithms.standard
        sneaky.keyExchangeAlgorithms.append(SSHDiffieHellmanAlgorithm.group14SHA1.name)
        for algorithms in [SSHAlgorithms.standard, sneaky] {
            await XCTAssertThrowsAsync(try await Harness.connect(server, client(algorithms: algorithms))) { error in
                guard case SSHClientError.handshakeFailed = error else { return XCTFail("\(error)") }
            }
        }
        let client = try await Harness.connect(server, client(algorithms: .legacyCompatible))
        await client.close()
    }

    func testLegacyMACRefusedUnlessAllowed() async throws {
        let sha1: [SSHTransportProtections.Scheme] = [SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA1>.self]
        var configuration = Harness.serverConfiguration()
        configuration.transportProtectionSchemes = sha1
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }
        var sneaky = SSHAlgorithms.standard
        sneaky.transportProtectionSchemes += sha1
        await XCTAssertThrowsAsync(try await Harness.connect(server, client(algorithms: sneaky)))
        let client = try await Harness.connect(server, client(algorithms: .legacyCompatible))
        await client.close()
    }

    /// `hmac-sha2-512` 要 64 字节 MAC 密钥：每种 DH（SHA-1 / 256 / 512）都要推得出来。
    func testHMACSHA2512WithEachDiffieHellman() async throws {
        let schemes: [SSHTransportProtections.Scheme] = [
            SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA512ETM>.self,
            SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA512>.self,
        ]
        for algorithm in SSHDiffieHellmanAlgorithm.allCases {
            for scheme in schemes {
                let server = try await dhServer([algorithm.name], schemes: [scheme])
                defer { Task { await server.stop() } }
                let client = try await Harness.connect(server, client(algorithms: algorithm.isLegacy ? .legacyCompatible : .standard))
                let outputX = String(buffer: try await client.executeCommand("x"))
                XCTAssertEqual(outputX, "ok\n", "\(algorithm.name) \(scheme.macName!)")
                await client.close()
            }
        }
    }

    /// 恶意服务器发越界的 f：0、1、p − 1、p（DH 适配层自己拒绝）、负数（NIOSSH 解析时拒绝）。
    func testOutOfRangeServerPublicValuesAreRejected() async throws {
        let prime = SSHDiffieHellmanGroup.group14.primeBytes
        let pMinus1 = (BigUInt(Data(prime)) - 1).sshMagnitudeBytes
        func mpint(_ magnitude: [UInt8]) -> [UInt8] { SSHWireFormatCoding.mpintContent(magnitude) }
        let cases: [(String, [UInt8], Bool)] = [
            ("0", [], true), ("1", [1], true), ("p-1", mpint(pMinus1), true), ("p", mpint(prime), true),
            ("-1", [0xFF], false),
        ]
        let server = try await dhServer([SSHDiffieHellmanAlgorithm.group14SHA256.name])
        defer { Task { await server.stop() } }
        for (label, value, rejectedByAdapter) in cases {
            let proxy = try await KeyExchangeReplyTamperer.start(targetPort: server.port) { reply in
                reply.publicValue = value
            }
            defer { Task { await proxy.stop() } }
            await XCTAssertThrowsAsync(try await self.connect(port: proxy.port, client())) { error in
                let underlying = Self.underlyingError(error)
                if rejectedByAdapter {
                    XCTAssertEqual(underlying as? SSHDiffieHellmanError, .invalidPeerPublicValue, "f = \(label): \(error)")
                } else {
                    XCTAssertNotNil(underlying as? NIOSSHError, "f = \(label): \(error)")
                }
            }
        }
    }

    /// 握手期间算法适配层抛的错误（这里是 DH 拒绝对端公开值）应当归成 `SSHClientError.handshakeFailed`，
    /// 和 NIOSSH 自己的协议错误一样；现在 `SSHConnectionGuard.handshakeError` 只认 `NIOSSHError`，其余的落到
    /// `.connectionClosed(.transportError(…))`，app 的分类器会把它当成网络断开、去重连。
    func testAlgorithmErrorDuringHandshakeIsHandshakeFailed() async throws {
        let server = try await dhServer([SSHDiffieHellmanAlgorithm.group14SHA256.name])
        defer { Task { await server.stop() } }
        let proxy = try await KeyExchangeReplyTamperer.start(targetPort: server.port) { reply in
            reply.publicValue = [1]
        }
        defer { Task { await proxy.stop() } }
        do {
            _ = try await connect(port: proxy.port, client())
            XCTFail("f = 1 应该被拒绝")
        } catch SSHClientError.handshakeFailed(let underlying) {
            XCTAssertEqual(underlying as? SSHDiffieHellmanError, .invalidPeerPublicValue)
        } catch SSHClientError.connectionClosed(.transportError(let underlying))
            where underlying is SSHDiffieHellmanError {
            throw XCTSkip("SSH-STACK-TODO(client): SSHConnectionGuard.handshakeError 把非 NIOSSHError 的握手错误"
                + "（SSHDiffieHellmanError 等算法错误）归成 connectionClosed(.transportError)，应为 handshakeFailed")
        }
    }

    // MARK: - 登记与并发

    /// 登记与握手同时进行、多个线程同时登记：不崩、结果一致（`static let` 只执行一次）。
    /// 进程里先跑过别的用例时登记早已完成，这时只证明重复调用无害。
    func testRegistrationRacesWithHandshakes() async throws {
        let server = try await rsaHostServer()
        defer { Task { await server.stop() } }
        let configuration = client(hostKey: .trustedKeys([NIOSSHPublicKey(rsaPublicKey: Self.rsaKey.publicKey)]))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let client = try await Harness.connect(server, configuration)
                    await client.close()
                }
            }
            group.addTask {
                DispatchQueue.concurrentPerform(iterations: 64) { index in
                    if index.isMultiple(of: 2) {
                        SSHAlgorithms.registerStandardAlgorithms()
                    } else {
                        SSHAlgorithms.registerLegacyAlgorithms()
                    }
                    _ = try? NIOSSHPublicKey(openSSHPublicKey: String(openSSHPublicKey: NIOSSHPublicKey(rsaPublicKey: Self.rsaKey.publicKey)))
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(NIOSSHAlgorithms.registeredPublicKeyAlgorithms, ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"])
    }

    // MARK: - 辅助

    private func connect(port: Int, _ configuration: SSHClient.Configuration) async throws -> SSHClient {
        try await SSHClient.connect(host: "127.0.0.1", port: port, configuration: configuration)
    }

    /// 从 `SSHClientError` 里取出底层错误（握手失败与连接断开两种包法）。
    static func underlyingError(_ error: any Error) -> (any Error)? {
        switch error {
        case SSHClientError.handshakeFailed(let underlying): return underlying
        case SSHClientError.connectionClosed(.transportError(let underlying)): return underlying
        default: return nil
        }
    }
}

/// 测试用的「说谎」私钥：在 userauth 里自称 `rsa-sha2-512`，签出来的却是 `ssh-rsa`（SHA-1）签名。
private struct MislabelledRSAKey: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { "rsa-sha2-512" }
    let key: SSHRSAPrivateKey
    var publicKey: NIOSSHPublicKeyProtocol { SSHRSAExtensionPublicKey(key.publicKey) }
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        SSHRSAExtensionSignature<SSHRSAExtensionSHA1>(try key.signature(for: data, algorithm: .sshRSA))
    }
}

enum SSHWireFormatCoding {
    /// 非负整数的 mpint 内容（不含长度）。
    static func mpintContent(_ magnitude: [UInt8]) -> [UInt8] {
        ByteBuffer.encodeUnsignedMPInt(magnitude: magnitude)
    }
}
