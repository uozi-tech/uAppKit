import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
@testable import USSHCore
import USSHTestServer
import XCTest

/// 重新交换密钥期间通道照常收发（NIOSSH 补丁 0012 / 0013）：exec、shell、direct-tcpip 的数据不丢、不乱序。
final class SSHRekeyChannelTests: XCTestCase {
    private let originator = try! SocketAddress(ipAddress: "127.0.0.1", port: 0)

    /// 第 i 个字节是 i % 251：丢了或乱了一眼就能看出来。
    static func pattern(_ count: Int, offset: Int = 0) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.reserveCapacity(count)
        for index in offset..<(offset + count) { buffer.writeInteger(UInt8(index % 251)) }
        return buffer
    }

    /// 核对收到的字节是不是 pattern 的连续一段，返回下一个期望的下标；不对就返回 nil。
    static func verify(_ buffer: ByteBuffer, from offset: Int) -> Int? {
        var index = offset
        for byte in buffer.readableBytesView {
            guard byte == UInt8(index % 251) else { return nil }
            index += 1
        }
        return index
    }

    /// 一边传数据一边不停地由两端交替发起重新交换，直到 `done` 置位。返回成功发起的次数。
    static func keepRekeying(_ client: SSHClient, _ server: SSHTestServer?, until done: NIOLockedValueBox<Bool>) async -> Int {
        var started = 0
        var turn = 0
        while !done.withLockedValue({ $0 }) {
            if turn % 2 == 0, let server {
                started += (try? await server.rekeyAllConnections()) ?? 0
            } else if await client.rekey() {
                started += 1
            }
            turn += 1
            try? await Task.sleep(for: .milliseconds(3))
        }
        return started
    }

    /// 往 `handle` 写 `total` 字节的 pattern 再发 EOF，同时读回并核对，一直读到通道关闭。
    static func streamThrough(_ handle: SSHSessionHandle, total: Int, chunk: Int = 32 * 1024) async throws -> Int {
        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                var sent = 0
                while sent < total {
                    let size = min(chunk, total - sent)
                    try await handle.write(pattern(size, offset: sent))
                    sent += size
                }
                try await handle.sendEOF()
                return -1
            }
            group.addTask {
                var expected = 0
                for try await piece in handle.output {
                    guard let next = verify(piece.buffer, from: expected) else {
                        XCTFail("data corrupted or reordered at byte \(expected)")
                        return expected
                    }
                    expected = next
                }
                return expected
            }
            var received = 0
            for try await value in group where value >= 0 { received = value }
            return received
        }
    }

    func testExecStdinRoundTripAcrossRepeatedRekeys() async throws {
        var configuration = Harness.serverConfiguration(exec: .echo)
        configuration.rekeyLimits = NIOSSHRekeyLimits(packets: 200, bytes: nil)   // 服务端也会按流量自己发起
        let server = try await SSHTestServer.start(configuration)
        let client = try await Harness.connect(server)
        defer { Task { await client.close(); await server.stop() } }

        let handle = try await client.openExec("cat")
        let done = NIOLockedValueBox(false)
        let rekeys = Task { await Self.keepRekeying(client, server, until: done) }
        let total = 4 * 1024 * 1024
        let received = try await Self.streamThrough(handle, total: total)
        done.withLockedValue { $0 = true }
        let started = await rekeys.value
        XCTAssertEqual(received, total)
        XCTAssertGreaterThan(started, 3, "the test did not actually rekey mid-stream")
        let status = await handle.exitStatus()
        XCTAssertEqual(status, .exited(0))
        XCTAssertTrue(client.isConnected)
    }

    func testShellWritesAcrossRekeys() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        let client = try await Harness.connect(server)
        defer { Task { await client.close(); await server.stop() } }

        let shell = try await client.openShell(pty: SSHPseudoTerminal())
        let done = NIOLockedValueBox(false)
        let rekeys = Task { await Self.keepRekeying(client, server, until: done) }
        // echoShell 遇到 0x04 会退出，pattern 里 4 % 251 会出现：避开它，用不含 0x04 的数据。
        let total = 512 * 1024
        var expected = 0
        var sent = 0
        var iterator = shell.output.makeAsyncIterator()
        while sent < total {
            let size = min(16 * 1024, total - sent)
            var buffer = ByteBuffer()
            buffer.writeRepeatingByte(UInt8(0x41 + (sent / size) % 26), count: size)
            try await shell.write(buffer)
            sent += size
            while expected < sent, let piece = try await iterator.next() {
                for byte in piece.buffer.readableBytesView {
                    XCTAssertEqual(byte, UInt8(0x41 + (expected / (16 * 1024)) % 26), "byte \(expected)")
                    expected += 1
                }
            }
        }
        done.withLockedValue { $0 = true }
        let started = await rekeys.value
        XCTAssertEqual(expected, total)
        XCTAssertGreaterThan(started, 0)
    }

    func testDirectTCPIPStreamAcrossRepeatedRekeys() async throws {
        let echo = try await EchoServer.start()
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        var configuration = Harness.clientConfiguration()
        configuration.rekeyLimits = NIOSSHRekeyLimits(packets: 300, bytes: nil)   // 客户端也按流量自己发起
        let client = try await Harness.connect(server, configuration)
        defer { Task { await client.close(); await server.stop(); await echo.stop() } }

        let channel = try await client.openDirectTCPIPAsyncChannel(
            targetHost: "127.0.0.1", targetPort: echo.port, originatorAddress: originator)
        let done = NIOLockedValueBox(false)
        let rekeys = Task { await Self.keepRekeying(client, server, until: done) }
        let total = 4 * 1024 * 1024
        let received = try await channel.executeThenClose { inbound, outbound in
            try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask {
                    var sent = 0
                    while sent < total {
                        let size = min(32 * 1024, total - sent)
                        try await outbound.write(Self.pattern(size, offset: sent))
                        sent += size
                    }
                    outbound.finish()
                    return -1
                }
                group.addTask {
                    var expected = 0
                    for try await buffer in inbound {
                        guard let next = Self.verify(buffer, from: expected) else {
                            XCTFail("data corrupted or reordered at byte \(expected)")
                            return expected
                        }
                        expected = next
                    }
                    return expected
                }
                var received = 0
                for try await value in group where value >= 0 { received = value }
                return received
            }
        }
        done.withLockedValue { $0 = true }
        let started = await rekeys.value
        XCTAssertEqual(received, total)
        XCTAssertGreaterThan(started, 3)
        XCTAssertTrue(client.isConnected)
    }
}
