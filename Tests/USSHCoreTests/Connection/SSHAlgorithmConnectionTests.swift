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

    /// 只开 SHA-1 用户认证回退（主机密钥 / 密钥交换仍是 `.standard`）：同一条连接上 512、256 被拒后最后试 `ssh-rsa`，
    /// 成功的算法记在 `rsaUserAuthenticationAlgorithm`；协商结果里没有任何旧算法。
    func testSHA1UserAuthFallbackWithoutServerSigAlgs() async throws {
        let server = try await rsaServer(accepting: [.sshRSA], acceptsLegacy: true)
        defer { Task { await server.stop() } }
        var configuration = client([.rsaPrivateKey(Self.rsaKey)])
        configuration.allowsSHA1RSAUserAuthenticationFallback = true
        let client = try await Harness.connect(server, configuration)
        defer { Task { await client.close() } }
        XCTAssertEqual(rsaAttempts(server), [.rsaSHA2_512, .rsaSHA2_256, .sshRSA])
        XCTAssertEqual(server.events.acceptedConnections, 1, "三次尝试都在同一条连接上")
        XCTAssertEqual(client.rsaUserAuthenticationAlgorithm, .sshRSA)
        XCTAssertEqual(client.negotiatedAlgorithms?.hostKey, "ssh-ed25519")
    }

    /// 宣告了不含 RSA 的 `server-sig-algs`：开了回退也一次 RSA 都不试。
    func testSHA1UserAuthFallbackFollowsServerSigAlgs() async throws {
        let server = try await rsaServer(accepting: [.sshRSA], serverSignatureAlgorithms: ["ssh-ed25519"], acceptsLegacy: true)
        defer { Task { await server.stop() } }
        var configuration = client([.rsaPrivateKey(Self.rsaKey)])
        configuration.allowsSHA1RSAUserAuthenticationFallback = true
        await XCTAssertThrowsAsync(try await Harness.connect(server, configuration)) { error in
            guard case SSHClientError.authenticationFailed(let failure) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(failure.attemptedMethods, [])
        }
        XCTAssertEqual(server.events.authAttempts.count, 0)
    }

    /// `SSHClient` 报出的协商结果：AES-GCM 时 MAC 不在用（`macInUse == nil`）；AES-CTR 时是协商到的 MAC；
    /// 口令登录时没有 RSA 算法。
    func testNegotiatedAlgorithmsAreExposed() async throws {
        let gcm = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await gcm.stop() } }
        let first = try await Harness.connect(gcm, client(algorithms: .builtInOnly))
        XCTAssertEqual(first.negotiatedAlgorithms, SSHNegotiatedAlgorithms(
            keyExchange: "curve25519-sha256", hostKey: "ssh-ed25519", encryption: "aes256-gcm@openssh.com",
            mac: "hmac-sha2-256", encryptionIsAEAD: true, compression: "none"))
        XCTAssertNil(first.negotiatedAlgorithms?.macInUse)
        XCTAssertNil(first.rsaUserAuthenticationAlgorithm)
        await first.close()

        var configuration = Harness.serverConfiguration()
        configuration.transportProtectionSchemes = [SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA1>.self]
        configuration.keyExchangeAlgorithms = [SSHDiffieHellmanAlgorithm.group14SHA1.name]
        let old = try await SSHTestServer.start(configuration)
        defer { Task { await old.stop() } }
        let second = try await Harness.connect(old, client(algorithms: .legacyCompatible))
        XCTAssertEqual(second.negotiatedAlgorithms?.keyExchange, "diffie-hellman-group14-sha1")
        XCTAssertEqual(second.negotiatedAlgorithms?.encryption, "aes128-ctr")
        XCTAssertEqual(second.negotiatedAlgorithms?.macInUse, "hmac-sha1")
        await second.close()
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

    /// 登记表是进程级的，但 `.builtInOnly` 的主机密钥列表里没有 RSA：协商不到，回调都不会被问。
    func testBuiltInOnlyRefusesRSAHostKeyEvenThoughRegistered() async throws {
        let server = try await rsaHostServer()
        defer { Task { await server.stop() } }
        let asked = NIOLockedValueBox(false)
        await XCTAssertThrowsAsync(try await Harness.connect(server, client(algorithms: .builtInOnly, hostKey: .custom { _ in
            asked.withLockedValue { $0 = true }
        }))) { error in
            guard case SSHClientError.noCommonAlgorithm(let failure) = error, failure.category == .hostKey
            else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(asked.withLockedValue { $0 })
    }

    /// 同一个进程里先有连接用过 `.legacyCompatible`（`ssh-rsa` 已登记），`.standard` 的连接照样不接受只提供
    /// `ssh-rsa` 主机密钥的服务器；之后 `.legacyCompatible` 仍然能连。
    func testSHA1HostKeyRefusedUnlessLegacyAllowedEvenAfterAnotherConnectionUsedIt() async throws {
        let server = try await rsaHostServer(algorithms: [.sshRSA])
        defer { Task { await server.stop() } }
        let first = try await Harness.connect(server, client(algorithms: .legacyCompatible))
        await first.close()
        XCTAssertTrue(SSHAlgorithms.legacyAlgorithmsRegistered)
        // 把 ssh-rsa 写进 .standard 的列表也不行：开关没开就滤掉。
        var sneaky = SSHAlgorithms.standard
        sneaky.hostKeyAlgorithms.append("ssh-rsa")
        for algorithms in [SSHAlgorithms.standard, sneaky] {
            await XCTAssertThrowsAsync(try await Harness.connect(server, client(algorithms: algorithms))) { error in
                guard case SSHClientError.noCommonAlgorithm(let failure) = error, failure.category == .hostKey,
                      failure.serverOffer == ["ssh-rsa"] else { return XCTFail("\(error)") }
            }
        }
        let again = try await Harness.connect(server, client(algorithms: .legacyCompatible))
        await again.close()
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

    /// 每种 DH 都能握手、跑命令，客户端发起换钥（`SSHClient.rekey()`）之后照样能用。服务器只提供这一种 DH，
    /// 所以换钥也走它。第二次 `rekey()` 只有在第一次交换完成之后才会返回 true，以此确认换钥做完了；
    /// 主机密钥按第一次交换钉住，换钥时不再问回调。
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
            let rekeyStarted = await client.rekey()
            XCTAssertTrue(rekeyStarted)
            let rekeyed = await Harness.eventually(timeout: Self.slowHandshake) { await client.rekey() }
            XCTAssertTrue(rekeyed, "\(algorithm.name) 换钥没有完成")
            let outputY = String(buffer: try await client.executeCommand("y"))
            XCTAssertEqual(outputY, "ok\n", algorithm.name)
            XCTAssertEqual(validations.value, 1, "换钥时主机密钥不再回调")
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
                guard case SSHClientError.noCommonAlgorithm(let failure) = error, failure.category == .keyExchange
                else { return XCTFail("\(error)") }
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

    /// 恶意服务器发越界的 f：0、1、负数（NIOSSH 解析时拒绝）、p − 1、p（DH 适配层拒绝）。
    func testOutOfRangeServerPublicValuesAreRejected() async throws {
        let prime = SSHDiffieHellmanGroup.group14.primeBytes
        let pMinus1 = (BigUInt(Data(prime)) - 1).sshMagnitudeBytes
        func mpint(_ magnitude: [UInt8]) -> [UInt8] { SSHWireFormatCoding.mpintContent(magnitude) }
        let cases: [(String, [UInt8], Bool)] = [
            // 0、1 与负数 NIOSSH 自己在读 mpint 时就拒绝（补丁 0006 的兜底）；p − 1、p 只有适配层知道。
            ("0", [], false), ("1", [1], false), ("p-1", mpint(pMinus1), true), ("p", mpint(prime), true),
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
                guard case SSHClientError.handshakeFailed(let underlying) = error else {
                    return XCTFail("f = \(label): \(error)")
                }
                if rejectedByAdapter {
                    XCTAssertEqual(underlying as? SSHDiffieHellmanError, .invalidPeerPublicValue, "f = \(label): \(error)")
                } else {
                    XCTAssertNotNil(underlying as? NIOSSHError, "f = \(label): \(error)")
                }
            }
        }
    }

    /// 握手期间算法适配层抛的错误（这里是 DH 拒绝对端公开值）归成 `SSHClientError.handshakeFailed`，
    /// 和 NIOSSH 自己的协议错误一样，不是 `.connectionClosed(.transportError(…))`（app 会当成断网去重连）。
    func testAlgorithmErrorDuringHandshakeIsHandshakeFailed() async throws {
        let server = try await dhServer([SSHDiffieHellmanAlgorithm.group14SHA256.name])
        defer { Task { await server.stop() } }
        let prime = SSHWireFormatCoding.mpintContent(SSHDiffieHellmanGroup.group14.primeBytes)
        let proxy = try await KeyExchangeReplyTamperer.start(targetPort: server.port) { reply in
            reply.publicValue = prime
        }
        defer { Task { await proxy.stop() } }
        await XCTAssertThrowsAsync(try await connect(port: proxy.port, client())) { error in
            guard case SSHClientError.handshakeFailed(let underlying) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(underlying as? SSHDiffieHellmanError, .invalidPeerPublicValue)
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
