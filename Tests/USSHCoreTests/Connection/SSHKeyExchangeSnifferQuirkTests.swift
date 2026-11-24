import Crypto
import NIOCore
import NIOEmbedded
import XCTest

@testable import NIOSSH
@testable import USSHCore

/// KEXINIT 嗅探器对 NIOSSH 也接受的那些「怪」输入：KEXINIT 之前的 SSH_MSG_IGNORE / SSH_MSG_DEBUG、name-list 里的
/// 空项与结尾逗号、超长名字、非 ASCII 字节。解析结果必须与 NIOSSH 自己的一致；在内存里跑一对真的 NIOSSH 客户端 /
/// 服务端，嗅探器的结论（协商成没成、成了是什么）必须与 NIOSSH 的结局一致——包括大量随机组合。
final class SSHKeyExchangeSnifferQuirkTests: XCTestCase {

    // MARK: - 解析与 NIOSSH 一致

    private func kexInitPayload(_ lists: [[UInt8]]) -> ByteBuffer {
        var payload = ByteBuffer()
        payload.writeInteger(UInt8(20))
        payload.writeBytes([UInt8](repeating: 9, count: 16))
        for list in lists {
            payload.writeInteger(UInt32(list.count))
            payload.writeBytes(list)
        }
        payload.writeInteger(UInt8(0))
        payload.writeInteger(UInt32(0))
        return payload
    }

    private func niosshParse(_ payload: ByteBuffer) throws -> SSHMessage.KeyExchangeMessage {
        var copy = payload
        guard case .keyExchange(let message) = try copy.readSSHMessage() else {
            throw XCTSkip("NIOSSH 没把它当 KEXINIT")
        }
        return message
    }

    func testNameListParsingMatchesNIOSSH() throws {
        let long = String(repeating: "x", count: 100) + "@example.com"
        let samples: [[UInt8]] = [
            Array("a,,b".utf8), Array("a,b,".utf8), Array(",a".utf8), Array("".utf8), Array(",".utf8), Array(",,,".utf8),
            Array("\(long),curve25519-sha256".utf8),
            [0x61, 0x80, 0xFF, 0x2C, 0x62],                    // 坏的 UTF-8
            Array("é,ü-mac,\u{7F}del,sp ace,tab\t".utf8),
            Array("a,\u{301}b,c".utf8),                        // 逗号后面跟组合字符：按字符切就不是分隔符
            Array("hmac-sha1,\u{0}nul".utf8),
        ]
        for sample in samples {
            let payload = kexInitPayload(Array(repeating: sample, count: 10))
            let theirs = try niosshParse(payload)
            var copy = payload
            let ours = try XCTUnwrap(SSHKeyExchangeInitSniffer.Reader.parseKeyExchangeInit(&copy), "\(sample)")
            let expected = theirs.keyExchangeAlgorithms.map(String.init)
            XCTAssertEqual(ours.keyExchange, expected, "\(sample)")
            XCTAssertEqual(ours.hostKey, theirs.serverHostKeyAlgorithms.map(String.init))
            XCTAssertEqual(ours.encryptionClientToServer, theirs.encryptionAlgorithmsClientToServer.map(String.init))
            XCTAssertEqual(ours.macServerToClient, theirs.macAlgorithmsServerToClient.map(String.init))
            XCTAssertEqual(ours.compressionClientToServer, theirs.compressionAlgorithmsClientToServer.map(String.init))
        }
    }

    private func packet(_ payload: [UInt8]) -> [UInt8] {
        var padding = 8 - (payload.count + 5) % 8
        if padding < 4 { padding += 8 }
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(payload.count + padding + 1))
        buffer.writeInteger(UInt8(padding))
        buffer.writeBytes(payload)
        buffer.writeBytes([UInt8](repeating: 0, count: padding))
        return Array(buffer.readableBytesView)
    }

    private static let ignore: [UInt8] = [2, 0, 0, 0, 3, 0x61, 0x62, 0x63]
    private static let debug: [UInt8] = [4, 1, 0, 0, 0, 4, 0x68, 0x65, 0x79, 0x0A, 0, 0, 0, 0]

    /// KEXINIT 之前的 IGNORE / DEBUG 跳过；别的类型（这里 SERVICE_REQUEST）放弃。
    func testReaderSkipsIgnoreAndDebugBeforeKEXINIT() {
        let kexinit = Array(kexInitPayload(Array(repeating: Array("curve25519-sha256".utf8), count: 10)).readableBytesView)
        var stream = Array("SSH-2.0-Old\r\n".utf8)
        stream += packet(Self.ignore) + packet(Self.debug) + packet(Self.ignore) + packet(kexinit)
        var reader = SSHKeyExchangeInitSniffer.Reader()
        var parsed: SSHKeyExchangeOffer?
        for byte in stream {
            if let offer = reader.feed(ByteBuffer(bytes: [byte])) { parsed = offer }
        }
        XCTAssertEqual(parsed?.keyExchange, ["curve25519-sha256"])
        XCTAssertTrue(reader.isDone)

        var other = SSHKeyExchangeInitSniffer.Reader()
        XCTAssertNil(other.feed(ByteBuffer(bytes: Array("SSH-2.0-Old\r\n".utf8) + packet([5, 0, 0, 0, 0]) + packet(kexinit))))
        XCTAssertTrue(other.isDone, "不是 IGNORE / DEBUG / KEXINIT 就放弃（NIOSSH 也会报协议错误）")
    }

    // MARK: - 与 NIOSSH 的结局一致（内存里的一对 NIOSSH）

    /// 一次在内存里的握手：客户端前面挂嗅探器（与 USSHCore 一样），服务端可以关掉 strict KEX、在 KEXINIT 之前插
    /// IGNORE / DEBUG、把 name-list 改成带空项和结尾逗号的写法（这些改动不影响交换哈希：NIOSSH 对 KEXINIT 是解析
    /// 之后重新序列化再算哈希）。
    struct Handshake {
        var clientKeyExchange: [String]
        var clientHostKeys: [String]
        var clientSchemes: [NIOSSHTransportProtection.Type]
        var serverKeyExchange: [String]
        var serverHostKeys: [NIOSSHPrivateKey]
        var serverSchemes: [NIOSSHTransportProtection.Type]
        var quirks = false
        /// 怪写法里也在 KEXINIT 之前插 IGNORE / DEBUG。注入的包不进服务端自己的包计数，之后的 MAC（按包序号算）
        /// 就对不上了，所以只配 AES-GCM（nonce 不看包序号）用；只看协商结论的随机组合里不插。
        var injectsPackets = true

        struct Outcome {
            var authenticated: Bool
            var niosshNegotiationFailed: Bool
            var otherError: (any Error)?
            var sniffed: Result<SSHNegotiatedAlgorithms, SSHAlgorithmNegotiationFailure>?
            var hostKeyType: String?
        }

        func run() throws -> Outcome {
            let loop = EmbeddedEventLoop()
            let client = EmbeddedChannel(loop: loop)
            let server = EmbeddedChannel(loop: loop)
            defer {
                _ = try? client.finish(acceptAlreadyClosed: true)
                _ = try? server.finish(acceptAlreadyClosed: true)
            }
            let hostKeyProbe = HostKeyProbe()
            var clientConfiguration = SSHClientConfiguration(
                userAuthDelegate: PasswordOffer(), serverAuthDelegate: hostKeyProbe,
                transportProtectionSchemes: clientSchemes)
            clientConfiguration.keyExchangeAlgorithms = clientKeyExchange
            clientConfiguration.hostKeyAlgorithms = clientHostKeys
            var serverConfiguration = SSHServerConfiguration(
                hostKeys: serverHostKeys, userAuthDelegate: AcceptAnyPassword(),
                transportProtectionSchemes: serverSchemes)
            serverConfiguration.keyExchangeAlgorithms = serverKeyExchange
            if quirks { serverConfiguration.offersStrictKeyExchange = false }

            let sniffer = SSHKeyExchangeInitSniffer(schemes: clientSchemes.map {
                SSHKeyExchangeInitSniffer.Scheme(cipher: $0.cipherName, mac: $0.macName)
            })
            let catcher = EventCatcher()
            try client.pipeline.syncOperations.addHandler(sniffer)
            try client.pipeline.syncOperations.addHandler(NIOSSHHandler(
                role: .client(clientConfiguration), allocator: client.allocator, inboundChildChannelInitializer: nil))
            try client.pipeline.syncOperations.addHandler(catcher)
            if quirks { try server.pipeline.syncOperations.addHandler(QuirkInjector(injectsPackets: injectsPackets)) }
            try server.pipeline.syncOperations.addHandler(NIOSSHHandler(
                role: .server(serverConfiguration), allocator: server.allocator, inboundChildChannelInitializer: nil))
            try client.connect(to: .init(unixDomainSocketPath: "/fake")).wait()
            try server.connect(to: .init(unixDomainSocketPath: "/fake")).wait()

            var workToDo = true
            var rounds = 0
            var serverFailed = false
            while workToDo, rounds < 200, catcher.error == nil, !catcher.authenticated {
                workToDo = false
                rounds += 1
                loop.run()
                if let data = try client.readOutbound(as: IOData.self), !serverFailed {
                    do {
                        try server.writeInbound(data)
                    } catch {
                        // 服务端那边出错（多半是它也协商失败）时 writeInbound 抛到这里。之后不再喂它，但它已经写出的
                        // 东西（它的 KEXINIT）照样交给客户端：客户端那边的结局才是要比的。
                        serverFailed = true
                    }
                    workToDo = true
                }
                if let data = try server.readOutbound(as: IOData.self) {
                    try client.writeInbound(data)
                    workToDo = true
                }
            }
            let sniffed: Result<SSHNegotiatedAlgorithms, SSHAlgorithmNegotiationFailure>?
            if let failure = sniffer.failure {
                sniffed = .failure(failure)
            } else if let negotiated = sniffer.negotiated {
                sniffed = .success(negotiated)
            } else {
                sniffed = nil
            }
            let niosshFailed = (catcher.error as? NIOSSHError)?.type == .keyExchangeNegotiationFailure
            return Outcome(authenticated: catcher.authenticated, niosshNegotiationFailed: niosshFailed,
                           otherError: niosshFailed ? nil : catcher.error, sniffed: sniffed,
                           hostKeyType: hostKeyProbe.keyType)
        }
    }

    /// 怪写法 + strict KEX 关掉的服务端：NIOSSH 握手照常成功，嗅探器读得出、结论一样。用 SHA-1 的 `ssh-rsa`
    /// 主机签名，证明这种情形下「用了旧算法」照样认得出来（以前嗅探器读不懂就放弃，旧算法悄悄用上）。
    func testQuirkyPeerStillNegotiatesAndIsSniffed() throws {
        SSHAlgorithms.registerStandardAlgorithms()
        SSHAlgorithms.registerLegacyAlgorithms()
        let rsa = try SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[1].pkcs1PEM)
        let outcome = try Handshake(
            clientKeyExchange: SSHAlgorithms.builtInKeyExchangeAlgorithms,
            clientHostKeys: ["ssh-ed25519", "ssh-rsa"],
            clientSchemes: Constants.bundledTransportProtectionSchemes,
            serverKeyExchange: ["ecdh-sha2-nistp256"],
            serverHostKeys: [NIOSSHPrivateKey(rsaPrivateKey: rsa, algorithm: .sshRSA)],
            serverSchemes: Constants.bundledTransportProtectionSchemes,
            quirks: true
        ).run()
        XCTAssertTrue(outcome.authenticated, "\(String(describing: outcome.otherError))")
        guard case .success(let negotiated) = outcome.sniffed else {
            return XCTFail("嗅探器应读出协商结果：\(String(describing: outcome.sniffed))")
        }
        XCTAssertEqual(negotiated.keyExchange, "ecdh-sha2-nistp256")
        XCTAssertEqual(negotiated.hostKey, "ssh-rsa")
        XCTAssertTrue(negotiated.encryptionIsAEAD)
    }

    /// 名字都对得上、本端却没有那个组合（aes128-ctr 只配 hmac-sha2-256，hmac-sha2-512 只配 aes256-ctr）：
    /// NIOSSH 协商失败，嗅探器也判失败。
    func testMissingCipherMACCombinationIsAFailureLikeNIOSSH() throws {
        let outcome = try Handshake(
            clientKeyExchange: ["curve25519-sha256"], clientHostKeys: ["ssh-ed25519"],
            clientSchemes: [SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256>.self,
                            SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA512>.self],
            serverKeyExchange: ["curve25519-sha256"], serverHostKeys: [NIOSSHPrivateKey(ed25519Key: .init())],
            serverSchemes: [SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256ETM>.self,
                            SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA512>.self]
        ).run()
        XCTAssertTrue(outcome.niosshNegotiationFailed)
        guard case .failure(let failure) = outcome.sniffed else { return XCTFail("\(String(describing: outcome.sniffed))") }
        XCTAssertEqual(failure.category, .encryption)
    }

    /// 大量随机组合：嗅探器的结论与 NIOSSH 的结局一一对应。成了的，嗅探出的主机密钥算法与服务端真拿来签名的
    /// 钥匙类型一致；NIOSSH 协商失败的，嗅探器一定也判了失败（且给得出类别）；反过来也一样。
    func testSnifferVerdictMatchesNIOSSHOverRandomOffers() throws {
        let kex = SSHAlgorithms.builtInKeyExchangeAlgorithms + ["unknown-kex@example.com"]
        let hostKeyNames = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384"]
        let hostKeys: [String: NIOSSHPrivateKey] = [
            "ssh-ed25519": NIOSSHPrivateKey(ed25519Key: .init()),
            "ecdsa-sha2-nistp256": NIOSSHPrivateKey(p256Key: .init()),
            "ecdsa-sha2-nistp384": NIOSSHPrivateKey(p384Key: .init()),
        ]
        let schemes: [NIOSSHTransportProtection.Type] = Constants.bundledTransportProtectionSchemes + [
            SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256>.self,
            SSHAESCTRTransportProtection<SSHAES256CTR, SSHHMACSHA512>.self,
            SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256ETM>.self,
        ]
        var generator = SplitMix64(seed: 0x5EED_CAFE)
        func subset<T>(_ items: [T]) -> [T] {
            var picked = items.shuffled(using: &generator).filter { _ in generator.next() % 3 != 0 }
            if picked.isEmpty { picked = [items.randomElement(using: &generator)!] }
            return picked
        }
        var successes = 0, failures = 0
        for round in 0..<Self.randomRounds {
            let serverHostKeyNames = subset(hostKeyNames)
            let handshake = Handshake(
                clientKeyExchange: subset(kex), clientHostKeys: subset(hostKeyNames), clientSchemes: subset(schemes),
                serverKeyExchange: subset(kex), serverHostKeys: serverHostKeyNames.map { hostKeys[$0]! },
                serverSchemes: subset(schemes), quirks: round % 2 == 1, injectsPackets: false)
            let outcome = try handshake.run()
            let context = "第 \(round) 轮：\(handshake.clientKeyExchange) / \(handshake.clientHostKeys) / "
                + "\(handshake.clientSchemes.map { "\($0.cipherName)+\($0.macName ?? "aead")" }) 对 "
                + "\(handshake.serverKeyExchange) / \(serverHostKeyNames) / "
                + "\(handshake.serverSchemes.map { "\($0.cipherName)+\($0.macName ?? "aead")" })"
            XCTAssertNil(outcome.otherError, context)
            switch outcome.sniffed {
            case .success(let negotiated):
                // 比的是客户端这一边的 NIOSSH（服务端缺某个加密组合时它自己会失败，那不是嗅探器的事）。
                XCTAssertFalse(outcome.niosshNegotiationFailed, "嗅探器说成，NIOSSH 却协商失败：\(context)")
                let known = handshake.clientKeyExchange.filter { $0 != "unknown-kex@example.com" }
                XCTAssertEqual(negotiated.keyExchange, known.first(where: handshake.serverKeyExchange.contains), context)
                if outcome.authenticated {
                    XCTAssertEqual(negotiated.hostKey, outcome.hostKeyType, context)
                    successes += 1
                }
            case .failure(let failure):
                XCTAssertTrue(outcome.niosshNegotiationFailed, "嗅探器说不成，NIOSSH 却没报协商失败：\(context)")
                XCTAssertNotNil(failure.category, context)
                failures += 1
            case nil:
                XCTFail("嗅探器没有结论：\(context)")
            }
        }
        XCTAssertGreaterThan(successes, Self.randomRounds / 10, "随机组合要两种结局都有不少（成了的按真的登录上算）")
        XCTAssertGreaterThan(failures, Self.randomRounds / 10)
    }

    static let randomRounds = 400
}

// MARK: - 辅助

/// 服务端出站：版本行之后的第一个包（KEXINIT）之前插一个 IGNORE 和一个 DEBUG，并把 KEXINIT 的每个 name-list
/// 改成 `,a,,b,` 的写法。
private final class QuirkInjector: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var versionSent = false
    private var done = false
    private let injectsPackets: Bool

    init(injectsPackets: Bool) { self.injectsPackets = injectsPackets }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buffer = unwrapOutboundIn(data)
        guard !done else { return context.write(data, promise: promise) }
        var out = ByteBuffer()
        if !versionSent {
            guard let newline = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
                return context.write(data, promise: promise)
            }
            var line = buffer.readSlice(length: newline - buffer.readerIndex + 1)!
            out.writeBuffer(&line)
            versionSent = true
        }
        if buffer.readableBytes > 0 {
            let length = Int(buffer.readInteger(as: UInt32.self)!)
            let padding = Int(buffer.readInteger(as: UInt8.self)!)
            var payload = buffer.readSlice(length: length - 1 - padding)!
            buffer.moveReaderIndex(forwardBy: padding)
            if injectsPackets {
                out.writeBytes(Self.packet([2, 0, 0, 0, 2, 0x68, 0x69]))
                out.writeBytes(Self.packet([4, 0, 0, 0, 0, 3, 0x6F, 0x6C, 0x64, 0, 0, 0, 0]))
            }
            out.writeBytes(Self.packet(Self.quirky(&payload)))
            out.writeBuffer(&buffer)
            done = true
        }
        context.write(wrapOutboundOut(out), promise: promise)
    }

    static func quirky(_ payload: inout ByteBuffer) -> [UInt8] {
        var out = ByteBuffer()
        out.writeBytes(payload.readBytes(length: 17)!)        // type + cookie
        for _ in 0..<10 {
            let length = Int(payload.readInteger(as: UInt32.self)!)
            let list = payload.readString(length: length)!
            let names = list.split(separator: ",")
            let rewritten = names.isEmpty ? "," : "," + names.joined(separator: ",,") + ","
            out.writeInteger(UInt32(rewritten.utf8.count))
            out.writeString(rewritten)
        }
        out.writeBuffer(&payload)
        return Array(out.readableBytesView)
    }

    static func packet(_ payload: [UInt8]) -> [UInt8] {
        var padding = 8 - (payload.count + 5) % 8
        if padding < 4 { padding += 8 }
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(payload.count + padding + 1))
        buffer.writeInteger(UInt8(padding))
        buffer.writeBytes(payload)
        buffer.writeBytes([UInt8](repeating: 0, count: padding))
        return Array(buffer.readableBytesView)
    }
}

private final class EventCatcher: ChannelInboundHandler {
    typealias InboundIn = Any
    var authenticated = false
    var error: (any Error)?

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { authenticated = true }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if self.error == nil { self.error = error }
    }
}

private final class HostKeyProbe: NIOSSHClientServerAuthenticationDelegate {
    var keyType: String?
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        keyType = String(String(openSSHPublicKey: hostKey).split(separator: " ")[0])
        validationCompletePromise.succeed(())
    }
}

private final class PasswordOffer: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.succeed(
            .init(username: "user", serviceName: "", offer: .password(.init(password: "pw"))))
    }
}

private final class AcceptAnyPassword: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        responsePromise.succeed(.success)
    }
}

/// 可复现的伪随机数（种子固定，失败时能重放）。
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
