import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
@testable import USSHCore
import XCTest

/// 经 `SSHClient` 对本机真实 sshd（OpenSSH 10.x）的算法互通矩阵：RSA 用户 / 主机密钥、每种 DH（含 sshd 发起的
/// 换钥）、每种 AES-CTR 组合（内置与 DH 两种密钥交换，核对 strict KEX）、`openSFTP` 对真的 sftp-server
/// （直连与跳板机，含换钥期间的大上传）、`-L` / `-R` 的两个方向半关闭。sshd 起不来时整组跳过。
///
/// 每条用例的 sshd 选项写在用例里；sshd 自己的日志（`LogLevel DEBUG1–3`）是协商结果的凭据。
final class OpenSSHAlgorithmInteropTests: XCTestCase {
    private func start(rsaHostKeyBits: Int? = nil, logLevel: String = "INFO",
                       extraConfig: [String] = []) async throws -> OpenSSHFixture {
        let fixture = try await OpenSSHFixture.start(
            extraConfig: extraConfig.joined(separator: "\n"), rsaHostKeyBits: rsaHostKeyBits, logLevel: logLevel)
        addTeardownBlock { fixture.stop() }
        return fixture
    }

    /// sshd 的日志是异步读进来的：等到包含 `needle`。
    private func waitForLog(_ fixture: OpenSSHFixture, _ needle: String) async -> Bool {
        await Harness.eventually { fixture.sshdLog.contains(needle) }
    }

    private static let outputBytes = 300_000
    private static let bulkCommand = "yes uterm-interop | head -c \(outputBytes)"

    private func assertBulkOutput(_ client: SSHClient, _ label: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let output = try await client.executeCommand(Self.bulkCommand)
        XCTAssertEqual(output.readableBytes, Self.outputBytes, label, file: file, line: line)
        let pattern = Array("uterm-interop\n".utf8)
        let expected = (0..<(Self.outputBytes / pattern.count + 1)).flatMap { _ in pattern }.prefix(Self.outputBytes)
        XCTAssertTrue(output.readableBytesView.elementsEqual(expected), label, file: file, line: line)
    }

    // MARK: - RSA 用户密钥

    /// sshd 默认（`server-sig-algs` 里有 rsa-sha2-512）：2048 / 4096 位都一次用 rsa-sha2-512 成功。
    func testRSAUserKeysAuthenticateWithRSASHA2512() async throws {
        let fixture = try await start(logLevel: "DEBUG2")
        for key in [fixture.rsa2048Key, fixture.rsa4096Key] {
            let client = try await fixture.connect(methods: [.rsaPrivateKey(key)])
            _ = try await client.executeCommand("true")
            await client.close()
        }
        let authenticated = await Harness.eventually {
            fixture.sshdLog.components(separatedBy: "authenticated 1 pkalg rsa-sha2-512").count - 1 == 2
        }
        XCTAssertTrue(authenticated, fixture.sshdLog)
        XCTAssertFalse(fixture.sshdLog.contains("attempting public key rsa-sha2-256"), "宣告了 server-sig-algs 就不该再试 256")
    }

    /// `PubkeyAcceptedAlgorithms rsa-sha2-256`：sshd 的 server-sig-algs 只剩 256，客户端第一次就用它。
    func testRSAUserKeyWithServerRestrictedToRSASHA2256() async throws {
        let fixture = try await start(logLevel: "DEBUG2", extraConfig: ["PubkeyAcceptedAlgorithms rsa-sha2-256"])
        for key in [fixture.rsa2048Key, fixture.rsa4096Key] {
            let client = try await fixture.connect(methods: [.rsaPrivateKey(key)])
            await client.close()
        }
        let authenticated = await Harness.eventually {
            fixture.sshdLog.components(separatedBy: "authenticated 1 pkalg rsa-sha2-256").count - 1 == 2
        }
        XCTAssertTrue(authenticated, fixture.sshdLog)
        XCTAssertFalse(fixture.sshdLog.contains("attempting public key rsa-sha2-512"))
    }

    /// `PubkeyAcceptedAlgorithms ssh-rsa`：标准预设干净地失败（RSA 一次都不试），旧算法预设用 ssh-rsa 成功。
    func testSSHRSAOnlyServerNeedsLegacy() async throws {
        let fixture = try await start(logLevel: "DEBUG2", extraConfig: ["PubkeyAcceptedAlgorithms ssh-rsa"])
        await XCTAssertThrowsAsync(try await fixture.connect(methods: [.rsaPrivateKey(fixture.rsa2048Key)], algorithms: .standard)) { error in
            guard case SSHClientError.authenticationFailed(let failure) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(failure.attemptedMethods, [])
        }
        let client = try await fixture.connect(methods: [.rsaPrivateKey(fixture.rsa2048Key)], algorithms: .legacyCompatible)
        await client.close()
        let authenticated = await waitForLog(fixture, "authenticated 1 pkalg ssh-rsa")
        XCTAssertTrue(authenticated, fixture.sshdLog)
    }

    // MARK: - RSA 主机密钥

    /// 只有 RSA 主机密钥的 sshd：回调拿到的钥匙和 `ssh-keygen -lf` 的指纹一致，连接可用。
    func testRSAOnlyHostKey() async throws {
        for algorithm in ["rsa-sha2-512", "rsa-sha2-256"] {
            let fixture = try await start(rsaHostKeyBits: 3072, logLevel: "DEBUG1", extraConfig: ["HostKeyAlgorithms \(algorithm)"])
            let seen = NIOLockedValueBox<NIOSSHPublicKey?>(nil)
            let client = try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)], algorithms: .standard,
                                                   hostKeyValidation: .custom { context in
                seen.withLockedValue { $0 = context.hostKey }
            })
            let hi = String(buffer: try await client.executeCommand("echo hi"))
            XCTAssertEqual(hi, "hi\n")
            await client.close()
            let hostKey = try XCTUnwrap(seen.withLockedValue { $0 })
            XCTAssertEqual(hostKey, fixture.hostKey)
            XCTAssertEqual(hostKey.rsaPublicKey?.modulusBitCount, 3072)
            var blob = ByteBuffer()
            hostKey.write(to: &blob)
            let ours = "SHA256:" + Data(SHA256.hash(data: blob.readableBytesView)).base64EncodedString()
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            let keygen = try OpenSSHFixture.run(OpenSSHFixture.sshKeygen, ["-lf", fixture.hostKeyPublicPath])
            XCTAssertTrue(keygen.contains(ours), "ssh-keygen: \(keygen) ours: \(ours)")
            let negotiated = await waitForLog(fixture, "kex: host key algorithm: \(algorithm)")
            XCTAssertTrue(negotiated, algorithm)

            // `.builtInOnly` 不报 RSA 主机密钥算法：协商失败。
            await XCTAssertThrowsAsync(try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)])) { error in
                guard case SSHClientError.noCommonAlgorithm(let failure) = error, failure.category == .hostKey
                else { return XCTFail("\(error)") }
            }
        }
    }

    /// `HostKeyAlgorithms ssh-rsa`：只有旧算法预设能连。
    func testSSHRSAHostKeyNeedsLegacy() async throws {
        let fixture = try await start(rsaHostKeyBits: 2048, logLevel: "DEBUG1", extraConfig: ["HostKeyAlgorithms ssh-rsa"])
        await XCTAssertThrowsAsync(try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)], algorithms: .standard)) { error in
            guard case SSHClientError.noCommonAlgorithm(let failure) = error, failure.category == .hostKey,
                  failure.serverOffer == ["ssh-rsa"] else { return XCTFail("\(error)") }
        }
        let client = try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)], algorithms: .legacyCompatible)
        await client.close()
        let negotiated = await waitForLog(fixture, "kex: host key algorithm: ssh-rsa")
        XCTAssertTrue(negotiated)
        // 用过旧算法之后，标准预设照样拒绝。
        await XCTAssertThrowsAsync(try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)], algorithms: .standard))
    }

    // MARK: - 自带密钥交换的先后

    /// sshd 不做任何限制时，三套预设都应该协商到 curve25519（我们把它排在最前，NIOSSH 自己的默认顺序是 P-384 在前）。
    func testDefaultKeyExchangeAgainstSSHDIsCurve25519() async throws {
        for (label, preset) in [("builtInOnly", SSHAlgorithms.builtInOnly), ("standard", .standard), ("legacyCompatible", .legacyCompatible)] {
            let fixture = try await start(logLevel: "DEBUG1")
            let client = try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)], algorithms: preset)
            await client.close()
            let negotiated = await waitForLog(fixture, "kex: algorithm: curve25519-sha256")
            XCTAssertTrue(negotiated, label)
        }
    }

    // MARK: - 有限域 DH

    /// sshd 钉死一种 DH，`RekeyLimit 64K` 让它在 300 KB 输出期间至少换钥一次。顺带量一次握手的耗时（客户端一侧）。
    func testEachDiffieHellmanAgainstSSHDIncludingServerRekey() async throws {
        var timings: [String] = []
        for algorithm in SSHDiffieHellmanAlgorithm.allCases {
            let fixture = try await start(logLevel: "DEBUG1", extraConfig: [
                "KexAlgorithms \(algorithm.name)", "RekeyLimit 64K",
            ])
            let presets: SSHAlgorithms = algorithm.isLegacy ? .legacyCompatible : .standard
            let started = ContinuousClock.now
            let client = try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)], algorithms: presets)
            timings.append("\(algorithm.name): \(ContinuousClock.now - started)")
            try await assertBulkOutput(client, algorithm.name)
            await client.close()
            let negotiated = await waitForLog(fixture, "kex: algorithm: \(algorithm.name)")
            XCTAssertTrue(negotiated, algorithm.name)
            XCTAssertGreaterThanOrEqual(fixture.keyExchangeCount, 2, "\(algorithm.name) 没有换钥")
            // 标准预设连只认 group14-sha1 的 sshd：没有共同算法。
            if algorithm.isLegacy {
                await XCTAssertThrowsAsync(try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)], algorithms: .standard))
            }
        }
        let fixture = try await start()
        let started = ContinuousClock.now
        let client = try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)])
        timings.append("curve25519 (built-in): \(ContinuousClock.now - started)")
        await client.close()
        print("[measure] handshake against sshd: " + timings.joined(separator: "; "))
    }

    // MARK: - 加密方式

    /// 预设里的每种 AES-CTR 组合，经 `SSHClient` 的配置选出来，分别配内置（curve25519）与 DH 两种密钥交换：
    /// sshd 记下的协商结果就是这一对、strict KEX 生效、300 KB 输出期间至少换钥一次。
    func testEachAESCTRSchemeWithBuiltInAndDiffieHellmanKeyExchange() async throws {
        let schemes = SSHAlgorithmsPresetSchemes.standardAESCTRSchemes + SSHAlgorithmsPresetSchemes.legacyAESCTRSchemes
        let legacy = Set(SSHAlgorithmsPresetSchemes.legacyAESCTRSchemes.map { ObjectIdentifier($0) })
        for kex in ["curve25519-sha256", "diffie-hellman-group14-sha256"] {
            let fixture = try await start(logLevel: "DEBUG3", extraConfig: [
                "KexAlgorithms \(kex)",
                "Ciphers aes128-ctr,aes192-ctr,aes256-ctr",
                "MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha1-etm@openssh.com,"
                    + "hmac-sha2-256,hmac-sha2-512,hmac-sha1",
                "RekeyLimit 64K",
            ])
            for scheme in schemes {
                let label = "\(scheme.cipherName) + \(scheme.macName!) [\(kex)]"
                let before = (kex: fixture.keyExchangeCount, strict: Self.strictCount(fixture))
                let algorithms = SSHAlgorithms(
                    transportProtectionSchemes: [scheme],
                    keyExchangeAlgorithms: SSHAlgorithms.standard.keyExchangeAlgorithms,
                    hostKeyAlgorithms: SSHAlgorithms.standard.hostKeyAlgorithms,
                    allowsLegacyAlgorithms: legacy.contains(ObjectIdentifier(scheme)))
                let client = try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)], algorithms: algorithms)
                try await assertBulkOutput(client, label)
                await client.close()
                let logged = await waitForLog(fixture, "cipher: \(scheme.cipherName) MAC: \(scheme.macName!) compression: none")
                XCTAssertTrue(logged, "\(label) sshd 日志里没有对应的协商记录")
                XCTAssertGreaterThanOrEqual(fixture.keyExchangeCount - before.kex, 2, "\(label) 没有换钥")
                XCTAssertGreaterThan(Self.strictCount(fixture), before.strict, "\(label) 没有协商 strict KEX")
            }
        }
    }

    /// `hmac-sha2-512`（要 64 字节 MAC 密钥）× 每种 DH 与内置密钥交换，ETM 与 E&M 各一次。
    func testHMACSHA2512WithEachKeyExchange() async throws {
        let schemes: [SSHTransportProtections.Scheme] = [
            SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA512ETM>.self,
            SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA512>.self,
        ]
        let kexes = SSHDiffieHellmanAlgorithm.allCases.map(\.name) + ["curve25519-sha256", "ecdh-sha2-nistp256", "ecdh-sha2-nistp384"]
        let fixture = try await start(logLevel: "DEBUG1", extraConfig: [
            "KexAlgorithms " + kexes.joined(separator: ","), "MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-512",
        ])
        for kex in kexes {
            for scheme in schemes {
                let algorithms = SSHAlgorithms(
                    transportProtectionSchemes: [scheme], keyExchangeAlgorithms: [kex],
                    hostKeyAlgorithms: SSHAlgorithms.standard.hostKeyAlgorithms,
                    allowsLegacyAlgorithms: SSHDiffieHellmanAlgorithm(name: kex)?.isLegacy == true)
                let client = try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)], algorithms: algorithms)
                let output = String(buffer: try await client.executeCommand("echo \(kex)"))
                XCTAssertEqual(output, "\(kex)\n", "\(kex) \(scheme.macName!)")
                await client.close()
            }
        }
    }

    /// OpenSSH 只在 DEBUG3 记 strict KEX：`kex_choose_conf: will use strict KEX ordering`（每次连接一行）。
    static let strictKEXEvidence = "will use strict KEX ordering"

    private static func strictCount(_ fixture: OpenSSHFixture) -> Int {
        fixture.sshdLog.components(separatedBy: strictKEXEvidence).count - 1
    }

    // MARK: - SFTP（openSFTP ↔ 真的 sftp-server）

    private func sftpRoot(_ fixture: OpenSSHFixture) throws -> String {
        let path = fixture.directory.appendingPathComponent("sftp-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return try XCTUnwrap(path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        })
    }

    private static func random(_ count: Int) -> ByteBuffer {
        var rng = SystemRandomNumberGenerator()
        var buffer = ByteBuffer()
        buffer.reserveCapacity(count)
        for _ in 0..<(count / 8) { buffer.writeInteger(rng.next()) }
        return buffer
    }

    /// 列目录、属性、64 MiB 上传下载（SHA-256 对账，也对磁盘）、96 个并发读、错误码。
    private func exerciseSFTP(_ sftp: SFTPClient, root: String, label: String) async throws {
        XCTAssertEqual(sftp.serverVersion, 3)
        XCTAssertNotNil(sftp.limits, "OpenSSH 宣告了 limits@openssh.com")
        try await sftp.createDirectory(root + "/d", attributes: SFTPFileAttributes(permissions: 0o750))
        let attributes = try await sftp.stat(root + "/d")
        XCTAssertEqual(attributes.permissions.map { $0 & 0o777 }, 0o750, label)

        let data = Self.random(64 << 20)
        let path = root + "/d/big.bin"
        let file = try await sftp.openFile(path, flags: [.write, .create, .truncate])
        try await file.write(contentsOf: data)
        try await file.close()
        let entries = try await sftp.listDirectory(root + "/d")
        XCTAssertEqual(entries.map(\.filename), ["big.bin"], label)
        XCTAssertEqual(entries.first?.attributes.size, UInt64(data.readableBytes), label)
        let digest = SHA256.hash(data: data.readableBytesView)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))), digest, "\(label) 磁盘上的内容")

        let reader = try await sftp.openFile(path, flags: .read)
        let back = try await reader.readAll()
        XCTAssertEqual(SHA256.hash(data: back.readableBytesView), digest, label)

        let chunk = sftp.maximumReadLength
        let reads = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<96 {
                group.addTask {
                    let offset = (index * 7919 % 255) * chunk
                    let part = try await reader.read(from: UInt64(offset), length: chunk)
                    return part.map { $0.readableBytesView.elementsEqual(data.getSlice(at: offset, length: chunk)!.readableBytesView) } ?? false
                }
            }
            return try await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
        }
        XCTAssertEqual(reads, 96, label)
        try await reader.close()

        // 错误码。
        await XCTAssertThrowsAsync(try await sftp.stat(root + "/missing")) { error in
            XCTAssertEqual((error as? SFTPError)?.statusCode, .noSuchFile, label)
        }
        await XCTAssertThrowsAsync(try await sftp.openFile(root + "/nope/x", flags: [.write, .create])) { error in
            XCTAssertEqual((error as? SFTPError)?.statusCode, .noSuchFile, label)
        }
        await XCTAssertThrowsAsync(try await sftp.createDirectory(root + "/d")) { error in
            XCTAssertEqual((error as? SFTPError)?.statusCode, .failure, label)
        }
        await XCTAssertThrowsAsync(try await sftp.removeDirectory(root + "/d")) { error in
            XCTAssertNotNil((error as? SFTPError)?.statusCode, label)
        }
        try await sftp.remove(path)
        try await sftp.removeDirectory(root + "/d")
    }

    func testOpenSFTPAgainstSFTPServer() async throws {
        let fixture = try await start()
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        let sftp = try await client.openSFTP()
        try await exerciseSFTP(sftp, root: try sftpRoot(fixture), label: "direct")
        await sftp.close()
    }

    func testOpenSFTPThroughJumpHost() async throws {
        let fixture = try await start()
        let outer = try await fixture.connect()
        defer { Task { await outer.close() } }
        let inner = try await outer.jump(to: "127.0.0.1", port: fixture.port, configuration: fixture.configuration())
        let sftp = try await inner.openSFTP()
        try await exerciseSFTP(sftp, root: try sftpRoot(fixture), label: "jump")
        await sftp.close()
        await inner.close()
    }

    /// `RekeyLimit 1M`：客户端大批写入的同时 sshd 一次次发起换钥（NIOSSH 补丁 0012 之前，换钥期间子通道的写入
    /// 直接失败），上传下载都要完整。
    func testSFTPUploadWhileServerRekeys() async throws {
        let fixture = try await start(logLevel: "DEBUG1", extraConfig: ["RekeyLimit 1M"])
        let client = try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)], algorithms: .standard)
        defer { Task { await client.close() } }
        let sftp = try await client.openSFTP()
        let root = try sftpRoot(fixture)
        let data = Self.random(24 << 20)
        let before = fixture.keyExchangeCount
        let file = try await sftp.openFile(root + "/up.bin", flags: [.read, .write, .create, .truncate])
        try await file.write(contentsOf: data, window: 64)
        let back = try await file.readAll()
        try await file.close()
        XCTAssertEqual(SHA256.hash(data: back.readableBytesView), SHA256.hash(data: data.readableBytesView))
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: root + "/up.bin"))),
                       SHA256.hash(data: data.readableBytesView))
        XCTAssertGreaterThanOrEqual(fixture.keyExchangeCount - before, 10, "上传期间应该换了很多次钥")
    }

    // MARK: - -L / -R

    /// `-L`：两个方向都有大量数据的同时 sshd 一次次换钥（`RekeyLimit 256K`），回显的字节一个不差。
    func testDirectTCPIPStreamAcrossRekeys() async throws {
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }
        let echoPort = echo.port
        let fixture = try await start(logLevel: "DEBUG1", extraConfig: ["RekeyLimit 256K"])
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        let before = fixture.keyExchangeCount
        let data = Self.random(6 << 20)
        let channel = try await client.openDirectTCPIPAsyncChannel(
            targetHost: "127.0.0.1", targetPort: echoPort, originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
        let echoed = try await channel.executeThenClose { inbound, outbound in
            try await withThrowingTaskGroup(of: ByteBuffer?.self) { group in
                group.addTask {
                    var copy = data
                    while copy.readableBytes > 0 {
                        try await outbound.write(copy.readSlice(length: min(32 * 1024, copy.readableBytes))!)
                    }
                    outbound.finish()
                    return nil
                }
                group.addTask {
                    var received = ByteBuffer()
                    for try await var buffer in inbound { received.writeBuffer(&buffer) }
                    return received
                }
                var result = ByteBuffer()
                for try await case let buffer? in group { result = buffer }
                return result
            }
        }
        XCTAssertEqual(echoed.readableBytes, data.readableBytes)
        XCTAssertEqual(echoed, data)
        XCTAssertGreaterThanOrEqual(fixture.keyExchangeCount - before, 5, "数据流期间应该换了几次钥")
    }

    /// `-L` 半关闭：本端先 EOF（回显服务读到 EOF 后发完再关），以及目标先 EOF（之后本端照样能写过去）。
    func testDirectTCPIPHalfCloseBothDirections() async throws {
        let fixture = try await start()
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)

        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }
        let first = try await client.openDirectTCPIPAsyncChannel(
            targetHost: "127.0.0.1", targetPort: echo.port, originatorAddress: originator)
        let echoed = try await first.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(string: "client EOF first"))
            outbound.finish()
            var text = ""
            for try await buffer in inbound { text += String(buffer: buffer) }
            return text
        }
        XCTAssertEqual(echoed, "client EOF first")

        let received = NIOLockedValueBox("")
        let target = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(SendThenHalfClose(received: received))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { Task { try? await target.close() } }
        let second = try await client.openDirectTCPIPAsyncChannel(
            targetHost: "127.0.0.1", targetPort: target.localAddress!.port!, originatorAddress: originator)
        let greeting = try await second.executeThenClose { inbound, outbound in
            var text = ""
            for try await buffer in inbound { text += String(buffer: buffer) }
            try await outbound.write(ByteBuffer(string: "after-eof"))
            outbound.finish()
            let delivered = await Harness.eventually { received.withLockedValue { $0 } == "after-eof" }
            XCTAssertTrue(delivered)
            return text
        }
        XCTAssertEqual(greeting, "bye")
    }

    /// `-R` 半关闭：连进 sshd 监听端口的一方先 EOF（本端回显完再关写方向），以及本端先 EOF。
    func testRemoteForwardHalfCloseBothDirections() async throws {
        let fixture = try await start()
        let client = try await fixture.connect()
        defer { Task { await client.close() } }

        let echoForward = try await client.startRemotePortForward(host: "127.0.0.1", port: 0) { channel, _ in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(EchoThenHalfClose())
            }
        }
        let echoed = try await Self.localExchange(port: echoForward.boundPort) { inbound, outbound in
            try await outbound.write(ByteBuffer(string: "peer EOF first"))
            outbound.finish()
            var text = ""
            for try await buffer in inbound { text += String(buffer: buffer) }
            return text
        }
        XCTAssertEqual(echoed, "peer EOF first")
        await echoForward.cancel()

        let received = NIOLockedValueBox("")
        let greeter = try await client.startRemotePortForward(host: "127.0.0.1", port: 0) { channel, _ in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(SendThenHalfClose(received: received))
            }
        }
        let greeting = try await Self.localExchange(port: greeter.boundPort) { inbound, outbound in
            var text = ""
            for try await buffer in inbound { text += String(buffer: buffer) }
            try await outbound.write(ByteBuffer(string: "after-eof"))
            outbound.finish()
            let delivered = await Harness.eventually { received.withLockedValue { $0 } == "after-eof" }
            XCTAssertTrue(delivered)
            return text
        }
        XCTAssertEqual(greeting, "bye")
        await greeter.cancel()
    }

    /// 连本机端口，开两个方向的半关闭，交给 `body`。
    private static func localExchange<R: Sendable>(
        port: Int,
        _ body: @escaping @Sendable (NIOAsyncChannelInboundStream<ByteBuffer>, NIOAsyncChannelOutboundWriter<ByteBuffer>) async throws -> R
    ) async throws -> R {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelOption(.allowRemoteHalfClosure, value: true)
            .connect(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(isOutboundHalfClosureEnabled: true))
                }
            }
        return try await channel.executeThenClose { inbound, outbound in try await body(inbound, outbound) }
    }
}

/// 回显；对端 EOF 后关掉自己的写方向。只用于小数据（之前的写入都已交给 socket）。
final class EchoThenHalfClose: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            context.close(mode: .output, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }
}
