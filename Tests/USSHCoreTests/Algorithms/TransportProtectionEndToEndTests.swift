import Crypto
import NIOCore
import NIOEmbedded
import XCTest

@testable import NIOSSH
@testable import USSHCore

/// 一对在内存里背靠背的 NIOSSH 客户端 / 服务端（与 swift-nio-ssh 自己的 EndToEndTests 同一做法），
/// 只给它们我们的加密方式，验证协商、整条包解析 / 序列化路径、换钥都能走通。
private final class InMemorySSHPair {
    let loop = EmbeddedEventLoop()
    let client: EmbeddedChannel
    let server: EmbeddedChannel
    private(set) var serverChildChannels: [Channel] = []

    init(clientSchemes: [NIOSSHTransportProtection.Type], serverSchemes: [NIOSSHTransportProtection.Type]) throws {
        self.client = EmbeddedChannel(loop: self.loop)
        self.server = EmbeddedChannel(loop: self.loop)

        let clientHandler = NIOSSHHandler(
            role: .client(
                .init(
                    userAuthDelegate: PasswordOffer(),
                    serverAuthDelegate: AcceptAnyHostKey(),
                    transportProtectionSchemes: clientSchemes
                )
            ),
            allocator: self.client.allocator,
            inboundChildChannelInitializer: nil
        )
        let serverHandler = NIOSSHHandler(
            role: .server(
                .init(
                    hostKeys: [.init(ed25519Key: .init())],
                    userAuthDelegate: AcceptAnyPassword(),
                    transportProtectionSchemes: serverSchemes
                )
            ),
            allocator: self.server.allocator
        ) { [unowned self] channel, _ in
            self.serverChildChannels.append(channel)
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(EchoHandler())
            }
        }
        try self.client.pipeline.syncOperations.addHandler(clientHandler)
        try self.server.pipeline.syncOperations.addHandler(serverHandler)
        try self.client.connect(to: .init(unixDomainSocketPath: "/fake")).wait()
        try self.server.connect(to: .init(unixDomainSocketPath: "/fake")).wait()
    }

    var clientSSH: NIOSSHHandler { try! self.client.pipeline.syncOperations.handler(type: NIOSSHHandler.self) }
    var serverSSH: NIOSSHHandler { try! self.server.pipeline.syncOperations.handler(type: NIOSSHHandler.self) }

    /// 来回搬字节直到两边都没有输出。返回搬过的总字节数。
    @discardableResult
    func interact() throws -> Int {
        var moved = 0
        var workToDo = true
        while workToDo {
            workToDo = false
            self.loop.run()
            if let data = try self.client.readOutbound(as: IOData.self) {
                if case .byteBuffer(let buffer) = data { moved += buffer.readableBytes }
                try self.server.writeInbound(data)
                workToDo = true
            }
            if let data = try self.server.readOutbound(as: IOData.self) {
                if case .byteBuffer(let buffer) = data { moved += buffer.readableBytes }
                try self.client.writeInbound(data)
                workToDo = true
            }
        }
        return moved
    }

    func openSession() throws -> (Channel, Collector) {
        let collector = Collector()
        var created: Channel?
        self.clientSSH.createChannel(nil, channelType: .session) { channel, _ in
            created = channel
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(collector)
            }
        }
        try self.interact()
        guard let channel = created else {
            throw ChannelError.inappropriateOperationForState
        }
        return (channel, collector)
    }

    func finish() throws {
        _ = try? self.client.finish(acceptAlreadyClosed: true)
        _ = try? self.server.finish(acceptAlreadyClosed: true)
        try self.loop.syncShutdownGracefully()
    }
}

private final class PasswordOffer: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.succeed(
            .init(username: "user", serviceName: "ssh-connection", offer: .password(.init(password: "pw")))
        )
    }
}

private final class AcceptAnyPassword: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        responsePromise.succeed(.success)
    }
}

private final class AcceptAnyHostKey: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

private final class EchoHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

private final class Collector: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    var received: [UInt8] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = self.unwrapInboundIn(data)
        if case .byteBuffer(let buffer) = message.data {
            self.received += buffer.readableBytesView
        }
    }
}

final class TransportProtectionEndToEndTests: XCTestCase {
    /// 进程内能跑通的方案：HMAC-SHA2-512 的那几个要 64 字节 MAC 密钥，两端都是 NIOSSH 时协商到的是
    /// ecdh-sha2-nistp384（摘要 48 字节），NIOSSH 推密钥时会 assert，所以不在这里测（见 `SSHTransportProtections`）。
    private static var schemes: [NIOSSHTransportProtection.Type] {
        SSHTransportProtections.modern + SSHTransportProtections.legacy
    }

    func testEachSchemeNegotiatesAndCarriesChannelDataAcrossRekeys() throws {
        for scheme in Self.schemes {
            let label = "\(scheme.cipherName) + \(scheme.macName!)"
            let pair = try InMemorySSHPair(clientSchemes: [scheme], serverSchemes: [scheme])
            defer { XCTAssertNoThrow(try pair.finish(), label) }
            try pair.interact()

            let (channel, collector) = try pair.openSession()
            XCTAssertEqual(pair.serverChildChannels.count, 1, label)

            var expected: [UInt8] = []
            func send(_ size: Int) throws {
                let bytes = TestKeys.random(size)
                expected += bytes
                channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes))), promise: nil)
                try pair.interact()
            }

            for size in [1, 15, 16, 17, 100, 1000, 30000] {
                try send(size)
            }
            // 客户端发起换钥，再发数据；然后服务端发起换钥，再发数据。
            try pair.clientSSH._rekey()
            try pair.interact()
            for size in [3, 4096, 65000] {
                try send(size)
            }
            try pair.serverSSH._rekey()
            try pair.interact()
            for size in [0, 2, 33] {
                try send(size)
            }
            XCTAssertEqual(collector.received.count, expected.count, label)
            XCTAssertEqual(collector.received, expected, label)
        }
    }

    /// 接在 NIOSSH 自带的 AES-GCM 之后：对端也有 GCM 时选 GCM；对端只有 CTR 时退到我们的方案。
    func testAppendingAfterBundledAESGCM() throws {
        let clientSchemes: [NIOSSHTransportProtection.Type] =
            Constants.bundledTransportProtectionSchemes + SSHTransportProtections.modern + SSHTransportProtections.legacy

        // 服务端只有 aes128-ctr + hmac-sha1：客户端的列表里 aes128-ctr 排在 GCM 后面也能协商成。
        let onlyLegacy = SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA1>.self
        let pair = try InMemorySSHPair(clientSchemes: clientSchemes, serverSchemes: [onlyLegacy])
        try pair.interact()
        let (channel, collector) = try pair.openSession()
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: "hello"))), promise: nil)
        try pair.interact()
        XCTAssertEqual(String(decoding: collector.received, as: UTF8.self), "hello")
        try pair.finish()

        // 两边都有 GCM 时仍是 GCM（我们的方案不会抢到前面）。
        let both = try InMemorySSHPair(
            clientSchemes: clientSchemes,
            serverSchemes: Constants.bundledTransportProtectionSchemes + SSHTransportProtections.modern
        )
        try both.interact()
        let (gcmChannel, gcmCollector) = try both.openSession()
        gcmChannel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: "gcm"))), promise: nil)
        try both.interact()
        XCTAssertEqual(String(decoding: gcmCollector.received, as: UTF8.self), "gcm")
        try both.finish()
    }

    /// 加密名相同、MAC 对不上时协商失败，而不是退到别的组合。
    func testMismatchedMACFailsNegotiation() throws {
        let pair = try InMemorySSHPair(
            clientSchemes: [SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA256>.self],
            serverSchemes: [SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA1>.self]
        )
        XCTAssertThrowsError(try pair.interact())
        try? pair.finish()
    }
}
