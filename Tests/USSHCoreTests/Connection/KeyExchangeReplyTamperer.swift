import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// 本机 TCP 中间人：客户端 → 服务端原样转发；服务端 → 客户端的第一个 KEX 回复（消息 31，
/// SSH_MSG_KEXDH_REPLY / KEX_ECDH_REPLY）交给 `rewrite` 改写后重新分包，其余原样转发。
///
/// 第一次 NEWKEYS 之前的包是明文、没有 MAC（RFC 4253 §6），所以能改；包数不变，序号（含 strict KEX）不受影响。
/// 用来模拟恶意服务器：越界的 DH 公开值、篡改的主机签名、换掉的签名算法名。
final class KeyExchangeReplyTamperer: Sendable {
    /// 回复的三段：string K_S、`f`（mpint 的内容，不含长度）、string 签名 blob（的内容）。
    struct Reply {
        var hostKey: [UInt8]
        var publicValue: [UInt8]
        var signature: [UInt8]
    }

    let port: Int
    private let listener: any Channel

    private init(port: Int, listener: any Channel) {
        self.port = port
        self.listener = listener
    }

    static func start(
        targetPort: Int,
        rewrite: @escaping @Sendable (inout Reply) -> Void
    ) async throws -> KeyExchangeReplyTamperer {
        let group = MultiThreadedEventLoopGroup.singleton
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.autoRead, value: false)
            .childChannelInitializer { inbound in
                // 两条通道在同一个 EventLoop 上；入站先不读，等出站连上、两头的 handler 都装好再开始读。
                ClientBootstrap(group: inbound.eventLoop)
                    .channelInitializer { outbound in
                        outbound.eventLoop.makeCompletedFuture {
                            try outbound.pipeline.syncOperations.addHandlers([
                                ByteToMessageHandler(ReplyRewriter(rewrite: rewrite)), Relay(peer: inbound),
                            ])
                        }
                    }
                    .connect(host: "127.0.0.1", port: targetPort)
                    .flatMapThrowing { outbound in
                        try inbound.pipeline.syncOperations.addHandler(Relay(peer: outbound))
                        inbound.closeFuture.whenComplete { _ in outbound.close(promise: nil) }
                        outbound.closeFuture.whenComplete { _ in inbound.close(promise: nil) }
                    }
                    .flatMap { inbound.setOption(.autoRead, value: true) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return KeyExchangeReplyTamperer(port: listener.localAddress!.port!, listener: listener)
    }

    func stop() async {
        try? await listener.close()
    }

    /// 收到什么就写给 `peer`。
    private final class Relay: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let peer: any Channel

        init(peer: any Channel) { self.peer = peer }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            peer.close(promise: nil)
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            context.close(promise: nil)
        }
    }

    /// 服务端 → 客户端方向：版本行原样，之后按 SSH 包切分，改写第一个消息 31，之后的字节原样。
    private struct ReplyRewriter: ByteToMessageDecoder {
        typealias InboundOut = ByteBuffer
        let rewrite: @Sendable (inout Reply) -> Void
        var sawVersion = false
        var done = false

        init(rewrite: @escaping @Sendable (inout Reply) -> Void) {
            self.rewrite = rewrite
        }

        mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
            if done {
                context.fireChannelRead(wrapInboundOut(buffer.readSlice(length: buffer.readableBytes)!))
                return .needMoreData
            }
            if !sawVersion {
                guard let newline = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else { return .needMoreData }
                let length = newline - buffer.readerIndex + 1
                context.fireChannelRead(wrapInboundOut(buffer.readSlice(length: length)!))
                sawVersion = true
                return .continue
            }
            guard let packetLength = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self),
                  buffer.readableBytes >= 4 + Int(packetLength) else {
                return .needMoreData
            }
            var packet = buffer.readSlice(length: 4 + Int(packetLength))!
            let original = packet
            _ = packet.readInteger(as: UInt32.self)
            let padding = Int(packet.readInteger(as: UInt8.self)!)
            var payload = packet.readSlice(length: packet.readableBytes - padding)!
            guard payload.getInteger(at: payload.readerIndex, as: UInt8.self) == 31 else {
                context.fireChannelRead(wrapInboundOut(original))
                return .continue
            }
            done = true
            payload.moveReaderIndex(forwardBy: 1)
            func string(_ buffer: inout ByteBuffer) -> [UInt8] {
                let length = Int(buffer.readInteger(as: UInt32.self)!)
                return buffer.readBytes(length: length)!
            }
            var reply = Reply(hostKey: string(&payload), publicValue: string(&payload), signature: string(&payload))
            rewrite(&reply)
            var newPayload = ByteBuffer()
            newPayload.writeInteger(UInt8(31))
            for field in [reply.hostKey, reply.publicValue, reply.signature] {
                newPayload.writeInteger(UInt32(field.count))
                newPayload.writeBytes(field)
            }
            // 块大小 8、填充至少 4 字节（RFC 4253 §6）。
            var paddingLength = 8 - (5 + newPayload.readableBytes) % 8
            if paddingLength < 4 { paddingLength += 8 }
            var out = ByteBuffer()
            out.writeInteger(UInt32(1 + newPayload.readableBytes + paddingLength))
            out.writeInteger(UInt8(paddingLength))
            out.writeBuffer(&newPayload)
            out.writeBytes([UInt8](repeating: 0, count: paddingLength))
            context.fireChannelRead(wrapInboundOut(out))
            return .continue
        }
    }
}

extension KeyExchangeReplyTamperer.Reply {
    /// 签名 blob 拆成（算法名，签名字节）。
    var signatureParts: (algorithm: String, bytes: [UInt8]) {
        get {
            var buffer = ByteBuffer(bytes: signature)
            let nameLength = Int(buffer.readInteger(as: UInt32.self)!)
            let name = buffer.readString(length: nameLength)!
            let bytesLength = Int(buffer.readInteger(as: UInt32.self)!)
            return (name, buffer.readBytes(length: bytesLength)!)
        }
        set {
            var buffer = ByteBuffer()
            buffer.writeInteger(UInt32(newValue.algorithm.utf8.count))
            buffer.writeString(newValue.algorithm)
            buffer.writeInteger(UInt32(newValue.bytes.count))
            buffer.writeBytes(newValue.bytes)
            signature = Array(buffer.readableBytesView)
        }
    }
}
