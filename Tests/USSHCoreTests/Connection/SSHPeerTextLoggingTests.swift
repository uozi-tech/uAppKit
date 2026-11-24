import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@testable import USSHCore
import XCTest

/// USSHCore 自己的调试日志里，NIOSSH 诊断文字夹带的对端原话（这里是对端的版本行）先消毒再写。
final class SSHPeerTextLoggingTests: XCTestCase {
    private final class Capture: LogHandler, @unchecked Sendable {
        let lines = NIOLockedValueBox<[String]>([])
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
                 source: String, file: String, function: String, line: UInt) {
            let text = "\(message) \(metadata.map { "\($0)" } ?? "")"
            lines.withLockedValue { $0.append(text) }
        }
    }

    func testPeerTextInNIOSSHDiagnosticsIsSanitizedInDebugLogs() async throws {
        let evilVersion = "SSH-1.5-evil\u{1B}]0;pwned\u{07}\u{202E}x\r\n"
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Greeter(text: evilVersion))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { listener.close(promise: nil) }
        let capture = Capture()
        var configuration = Harness.clientConfiguration(handshakeTimeout: .seconds(5))
        configuration.logger = Logger(label: "test") { _ in capture }
        do {
            let client = try await SSHClient.connect(host: "127.0.0.1", port: listener.localAddress!.port!,
                                                     configuration: configuration)
            await client.close()
            XCTFail("应当失败")
        } catch {}
        let lines = capture.lines.withLockedValue { $0 }
        let errorLine = try XCTUnwrap(lines.first { $0.contains("SSH 连接出错") }, "\(lines)")
        XCTAssertTrue(errorLine.contains("evil"), errorLine)
        XCTAssertFalse(errorLine.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 || $0.value == 0x202E }, errorLine)
        XCTAssertFalse(errorLine.contains("\r"), errorLine)
    }

    /// 连上就发一行。
    private final class Greeter: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        let text: String
        init(text: String) { self.text = text }
        func channelActive(context: ChannelHandlerContext) {
            context.writeAndFlush(NIOAny(ByteBuffer(string: text)), promise: nil)
            context.fireChannelActive()
        }
    }
}
