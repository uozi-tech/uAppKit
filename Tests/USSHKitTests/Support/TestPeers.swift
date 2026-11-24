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
        let c = try! OpenSSHRSADecoder.decodeComponents(openSSHText: text)
        return rsa(n: c.modulus, e: c.publicExponent, d: c.privateExponent, iqmp: [1], p: [], q: [])
    }

    /// 用给定的分量拼一个明文 RSA 容器。公钥段默认由 (e, n) 生成，`publicBlob` 给了就用它（拼「公钥段与私钥段
    /// 不是同一把钥匙」的文件）。
    static func rsa(n: [UInt8], e: [UInt8], d: [UInt8], iqmp: [UInt8], p: [UInt8], q: [UInt8],
                    publicBlob: [UInt8]? = nil, comment: String = "test") -> String {
        var section = SSHWireWriter()
        section.writeString("ssh-rsa")
        section.writeMPInt(n)
        section.writeMPInt(e)
        section.writeMPInt(d)
        section.writeMPInt(iqmp)
        section.writeMPInt(p)
        section.writeMPInt(q)
        return container(publicBlob: publicBlob ?? SSHPublicMaterial.rsaBlob(e: e, n: n),
                         keyFields: section.bytes, comment: comment)
    }

    /// 明文容器：公钥段 `publicBlob`，私钥段 = checkint ×2 ‖ `keyFields`（含类型名）‖ 注释 ‖ 填充。
    static func container(publicBlob: [UInt8], keyFields: [UInt8], comment: String = "test") -> String {
        var section = SSHWireWriter()
        section.writeUInt32(0x1234_5678)
        section.writeUInt32(0x1234_5678)
        section.writeRawBytes(keyFields)
        section.writeString(comment)
        var padded = section.bytes
        var pad: UInt8 = 1
        while padded.count % 8 != 0 {
            padded.append(pad)
            pad += 1
        }
        var out = SSHWireWriter()
        out.writeRawBytes(Array("openssh-key-v1\u{0}".utf8))
        out.writeString("none")
        out.writeString("none")
        out.writeString([UInt8]())
        out.writeUInt32(1)
        out.writeString(publicBlob)
        out.writeString(padded)
        return armor(out.bytes)
    }

    static func armor(_ bytes: [UInt8]) -> String {
        let base64 = Array(Data(bytes).base64EncodedString())
        let lines = stride(from: 0, to: base64.count, by: 70).map { String(base64[$0..<min($0 + 70, base64.count)]) }
        return (["-----BEGIN OPENSSH PRIVATE KEY-----"] + lines + ["-----END OPENSSH PRIVATE KEY-----"])
            .joined(separator: "\n") + "\n"
    }
}
