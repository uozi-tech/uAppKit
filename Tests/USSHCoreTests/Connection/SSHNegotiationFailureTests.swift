import NIOCore
@testable import NIOSSH
@testable import USSHCore
import USSHTestServer
import XCTest

/// 双方没有共同算法时的报错：`SSHClientError.noCommonAlgorithm`，带类别与服务器的报价；每种都连很多次，证明结果
/// 与「先处理对端的关闭还是先处理 KEXINIT」无关。对本机真实 sshd 的同类用例在 `OpenSSHAlgorithmInteropTests`。
final class SSHNegotiationFailureTests: XCTestCase {
    static let rsaKey = try! SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[1].pkcs1PEM)
    static let attempts = 12

    private func configuration(_ algorithms: SSHAlgorithms) -> SSHClient.Configuration {
        var configuration = Harness.clientConfiguration(handshakeTimeout: .seconds(60))
        configuration.algorithms = algorithms
        return configuration
    }

    /// 连 `attempts` 次，每次都必须是 `noCommonAlgorithm`，返回各次的详情。
    private func failures(_ server: SSHTestServer, _ algorithms: SSHAlgorithms,
                          file: StaticString = #filePath, line: UInt = #line) async -> [SSHAlgorithmNegotiationFailure] {
        var result: [SSHAlgorithmNegotiationFailure] = []
        for attempt in 0..<Self.attempts {
            do {
                let client = try await Harness.connect(server, configuration(algorithms))
                await client.close()
                XCTFail("第 \(attempt) 次居然连上了", file: file, line: line)
            } catch SSHClientError.noCommonAlgorithm(let failure) {
                result.append(failure)
            } catch {
                XCTFail("第 \(attempt) 次应是 noCommonAlgorithm，实际 \(String(reflecting: error))", file: file, line: line)
            }
        }
        return result
    }

    func testHostKeyMismatchIsTypedAndDeterministic() async throws {
        var configuration = Harness.serverConfiguration()
        configuration.useRSAHostKey(Self.rsaKey)
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }

        let failures = await failures(server, .builtInOnly)
        XCTAssertEqual(failures.count, Self.attempts)
        for failure in failures {
            XCTAssertEqual(failure.category, .hostKey)
            XCTAssertEqual(failure.serverOffer, ["rsa-sha2-512", "rsa-sha2-256"])
            XCTAssertEqual(failure.clientOffer, SSHAlgorithms.builtInOnly.hostKeyAlgorithms)
        }
        XCTAssertTrue(server.events.authAttempts.isEmpty)
    }

    func testKeyExchangeMismatchIsTypedAndDeterministic() async throws {
        var configuration = Harness.serverConfiguration()
        configuration.keyExchangeAlgorithms = [SSHDiffieHellmanAlgorithm.group14SHA1.name]
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }

        for failure in await failures(server, .standard) {
            XCTAssertEqual(failure.category, .keyExchange)
            XCTAssertEqual(failure.serverOffer, ["diffie-hellman-group14-sha1"])
            XCTAssertFalse(failure.clientOffer.contains { $0.hasPrefix("ext-info") || $0.hasPrefix("kex-strict") },
                           "标记不是算法，不该报出去")
        }
    }

    func testEncryptionMismatchIsTypedAndDeterministic() async throws {
        var configuration = Harness.serverConfiguration()
        configuration.transportProtectionSchemes = [SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256>.self]
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }

        for failure in await failures(server, .builtInOnly) {
            XCTAssertEqual(failure.category, .encryption)
            XCTAssertEqual(failure.serverOffer, ["aes128-ctr"])
        }
    }

    /// 加密对得上（AES-GCM），MAC 对不上：NIOSSH 连 AEAD 也要求 MAC 名字有交集（自己只有 AES-GCM 时报一个
    /// `hmac-sha2-256` 占位）。
    func testMACMismatchIsTypedAndDeterministic() async throws {
        var configuration = Harness.serverConfiguration()
        configuration.transportProtectionSchemes = Constants.bundledTransportProtectionSchemes
            + [SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA512>.self]
        let server = try await SSHTestServer.start(configuration)
        defer { Task { await server.stop() } }

        for failure in await failures(server, .builtInOnly) {
            XCTAssertEqual(failure.category, .mac)
            XCTAssertEqual(failure.serverOffer, ["hmac-sha2-512"])
            XCTAssertEqual(failure.clientOffer, ["hmac-sha2-256"])
        }
    }

    // MARK: - 协商规则（不经网络）

    private func offer(kex: [String] = ["curve25519-sha256"], hostKey: [String] = ["ssh-ed25519"],
                       cipher: [String] = ["aes128-gcm@openssh.com"], mac: [String] = ["hmac-sha2-256"],
                       compression: [String] = ["none"]) -> SSHKeyExchangeOffer {
        SSHKeyExchangeOffer(keyExchange: kex, hostKey: hostKey,
                            encryptionClientToServer: cipher, encryptionServerToClient: cipher,
                            macClientToServer: mac, macServerToClient: mac,
                            compressionClientToServer: compression, compressionServerToClient: compression)
    }

    func testNegotiationRules() {
        func failure(_ client: SSHKeyExchangeOffer, _ server: SSHKeyExchangeOffer) -> SSHAlgorithmNegotiationFailure? {
            if case .failure(let failure) = SSHKeyExchangeInitSniffer.negotiate(client: client, server: server) { return failure }
            return nil
        }
        let client = offer(kex: ["curve25519-sha256", "ext-info-c", "kex-strict-c-v00@openssh.com"])
        XCTAssertEqual(try SSHKeyExchangeInitSniffer.negotiate(
            client: client, server: offer(kex: ["curve25519-sha256", "kex-strict-s-v00@openssh.com"])).get(),
            SSHNegotiatedAlgorithms(keyExchange: "curve25519-sha256", hostKey: "ssh-ed25519",
                                    encryption: "aes128-gcm@openssh.com", mac: "hmac-sha2-256", encryptionIsAEAD: false,
                                    compression: "none"),
            "这里只看名字；AEAD 与否由嗅探器按本端的配置补上")
        XCTAssertEqual(failure(client, offer(kex: ["diffie-hellman-group1-sha1"])),
                       .init(category: .keyExchange, clientOffer: ["curve25519-sha256"], serverOffer: ["diffie-hellman-group1-sha1"]))
        XCTAssertEqual(failure(client, offer(hostKey: ["ssh-dss"]))?.category, .hostKey)
        XCTAssertEqual(failure(client, offer(cipher: ["aes128-cbc"]))?.category, .encryption)
        XCTAssertEqual(failure(client, offer(mac: ["hmac-md5"]))?.category, .mac)
        XCTAssertEqual(failure(client, offer(compression: ["zlib"])),
                       .init(category: .compression, clientOffer: ["none"], serverOffer: ["zlib"]))
        // 两个方向的结果不同：NIOSSH 只支持对称的结果。
        var asymmetric = offer(cipher: ["aes128-gcm@openssh.com", "aes256-gcm@openssh.com"])
        asymmetric.encryptionServerToClient = ["aes256-gcm@openssh.com", "aes128-gcm@openssh.com"]
        let both = offer(cipher: ["aes256-gcm@openssh.com", "aes128-gcm@openssh.com"])
        XCTAssertEqual(failure(asymmetric, both)?.category, .encryption)
        // 选的是客户端列表里第一个双方都有的。
        let picked = try? SSHKeyExchangeInitSniffer.negotiate(
            client: offer(kex: ["curve25519-sha256", "diffie-hellman-group14-sha1"], hostKey: ["ssh-ed25519", "ssh-rsa"]),
            server: offer(kex: ["diffie-hellman-group14-sha1", "curve25519-sha256"], hostKey: ["ssh-rsa"])).get()
        XCTAssertEqual(picked?.keyExchange, "curve25519-sha256")
        XCTAssertEqual(picked?.hostKey, "ssh-rsa")
    }

    /// 读第一个包：横幅行、版本行、KEXINIT 被拆成很多段送进来也能读出。
    func testReaderParsesKEXINITAcrossFragments() throws {
        var payload = ByteBuffer()
        payload.writeInteger(UInt8(20))
        payload.writeBytes([UInt8](repeating: 7, count: 16))
        let lists = [["curve25519-sha256"], ["ssh-ed25519", "rsa-sha2-512"], ["aes128-ctr"], ["aes128-ctr"],
                     ["hmac-sha2-256"], ["hmac-sha2-256"], ["none"], ["none"], [], []]
        for list in lists {
            let joined = list.joined(separator: ",")
            payload.writeInteger(UInt32(joined.utf8.count))
            payload.writeString(joined)
        }
        payload.writeInteger(UInt8(0))
        payload.writeInteger(UInt32(0))
        let padding = 8 - (payload.readableBytes + 5) % 8 + 8
        var stream = ByteBuffer(string: "Welcome\r\nSSH-2.0-Test\r\n")
        stream.writeInteger(UInt32(payload.readableBytes + padding + 1))
        stream.writeInteger(UInt8(padding))
        stream.writeBuffer(&payload)
        stream.writeBytes([UInt8](repeating: 0, count: padding))
        stream.writeString("garbage after the first packet")

        var reader = SSHKeyExchangeInitSniffer.Reader()
        var parsed: SSHKeyExchangeOffer?
        while stream.readableBytes > 0 {
            let chunk = stream.readSlice(length: min(3, stream.readableBytes))!
            if let offer = reader.feed(chunk) { parsed = offer }
        }
        XCTAssertEqual(parsed?.hostKey, ["ssh-ed25519", "rsa-sha2-512"])
        XCTAssertEqual(parsed?.encryptionClientToServer, ["aes128-ctr"])
        XCTAssertTrue(reader.isDone)
    }

    func testReaderGivesUpOnNonKEXINIT() {
        var stream = ByteBuffer(string: "SSH-2.0-Test\r\n")
        stream.writeInteger(UInt32(12))
        stream.writeInteger(UInt8(4))
        stream.writeBytes([21, 0, 0, 0, 0, 0, 0])   // NEWKEYS，不是 KEXINIT
        stream.writeBytes([0, 0, 0, 0])
        var reader = SSHKeyExchangeInitSniffer.Reader()
        XCTAssertNil(reader.feed(stream))
        XCTAssertTrue(reader.isDone)
    }
}
