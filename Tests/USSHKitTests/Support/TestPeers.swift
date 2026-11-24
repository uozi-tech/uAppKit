import Foundation
import NIOCore
import NIOPosix
@testable import USSHKit

/// 接受连接后立刻发一段问候的 TCP 服务（模拟服务器先说话的协议）。
enum GreetingServer {
    struct Handle: Sendable {
        let channel: any Channel
        var port: Int { channel.localAddress?.port ?? 0 }
        func close() async throws { try await channel.close() }
    }

    final class Greeter: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let greeting: String
        init(greeting: String) { self.greeting = greeting }
        func channelActive(context: ChannelHandlerContext) {
            let buffer = context.channel.allocator.buffer(string: greeting)
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }

    static func start(greeting: String) async throws -> Handle {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Greeter(greeting: greeting))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return Handle(channel: channel)
    }
}

/// 拼几个解码器自己读不动、要专门处理的 OpenSSH 容器。
enum OpenSSHTestContainers {
    /// 把明文 RSA 容器私钥段里的 p、q 换成空串（只剩 n / e / d）。迁移前这种容器靠 Citadel 的 SHA-1
    /// 老路导入；现在由 `RSAKeyMaterial.recoverPrimes` 还原素因子。
    static func rsaWithoutPrimes(_ text: String) -> String {
        let der = try! PEMDocument.parse(text).der
        let magic = Array("openssh-key-v1\u{0}".utf8)
        var reader = SSHWireReader(Array(der.dropFirst(magic.count)))
        let cipher = try! reader.readString()
        let kdf = try! reader.readString()
        let kdfOptions = try! reader.readString()
        let count = try! reader.readUInt32()
        let publicKey = try! reader.readString()
        var privateSection = SSHWireReader(try! reader.readString())
        let check = try! privateSection.readUInt32()
        _ = try! privateSection.readUInt32()
        let keyType = try! privateSection.readString()
        let n = try! privateSection.readMPInt()
        let e = try! privateSection.readMPInt()
        let d = try! privateSection.readMPInt()
        let iqmp = try! privateSection.readMPInt()
        _ = try! privateSection.readMPInt()
        _ = try! privateSection.readMPInt()
        let comment = try! privateSection.readString()

        var section = SSHWireWriter()
        section.writeUInt32(check)
        section.writeUInt32(check)
        section.writeString(keyType)
        section.writeMPInt(n)
        section.writeMPInt(e)
        section.writeMPInt(d)
        section.writeMPInt(iqmp)
        section.writeString([UInt8]())
        section.writeString([UInt8]())
        section.writeString(comment)
        var padded = section.bytes
        var pad: UInt8 = 1
        while padded.count % 8 != 0 {
            padded.append(pad)
            pad += 1
        }

        var out = SSHWireWriter()
        out.writeRawBytes(magic)
        out.writeString(cipher)
        out.writeString(kdf)
        out.writeString(kdfOptions)
        out.writeUInt32(count)
        out.writeString(publicKey)
        out.writeString(padded)
        let base64 = Array(Data(out.bytes).base64EncodedString())
        let lines = stride(from: 0, to: base64.count, by: 70).map { String(base64[$0..<min($0 + 70, base64.count)]) }
        return (["-----BEGIN OPENSSH PRIVATE KEY-----"] + lines + ["-----END OPENSSH PRIVATE KEY-----"])
            .joined(separator: "\n") + "\n"
    }
}
