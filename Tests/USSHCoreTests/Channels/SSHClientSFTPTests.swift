import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
@testable import USSHCore
import USSHTestServer
import XCTest

/// `SSHClient.openSFTP` 经真的 SSH 连接（进程内服务端的 `serveSFTP`）对接 `SFTPClient`：
/// 字节流、可写性（小窗口下的大写入）、通道 / 连接断开时在途请求失败、subsystem 被拒。
final class SSHClientSFTPTests: XCTestCase {
    private var fileSystem: SFTPLocalFileSystem!
    private var faults: SFTPFaultInjector!
    private var server: SSHTestServer!

    override func setUp() async throws {
        fileSystem = try SFTPLocalFileSystem.makeTemporary()
        faults = SFTPFaultInjector()
    }

    override func tearDown() async throws {
        await server?.stop()
        try? fileSystem?.removeRoot()
    }

    private func start(maximumPacketSize: Int = 1 << 17) async throws {
        var configuration = Harness.serverConfiguration()
        configuration.serveSFTP(fileSystem: fileSystem, faults: faults)
        configuration.maximumPacketSize = maximumPacketSize
        server = try await SSHTestServer.start(configuration)
    }

    private func connect(maximumPacketSize: Int = SSHClient.defaultMaximumPacketSize) async throws -> SSHClient {
        var configuration = Harness.clientConfiguration()
        configuration.maximumPacketSize = maximumPacketSize
        return try await Harness.connect(server, configuration)
    }

    private static func random(_ count: Int) -> ByteBuffer {
        var rng = SystemRandomNumberGenerator()
        var buffer = ByteBuffer()
        buffer.reserveCapacity(count)
        for _ in 0..<(count / 8) { buffer.writeInteger(rng.next()) }
        return buffer
    }

    func testOpenSFTPEndToEnd() async throws {
        try await start()
        let client = try await connect()
        defer { Task { await client.close() } }
        let sftp = try await client.openSFTP()
        XCTAssertEqual(sftp.serverVersion, 3)
        XCTAssertEqual(sftp.maximumReadLength, 255 * 1024, "limits@openssh.com 问到了")
        XCTAssertEqual(server.events.subsystems, ["sftp"])

        // 默认窗口够放 readAll 默认的 16 个在途 READ。
        XCTAssertGreaterThanOrEqual(Harness.clientConfiguration().channelWindowSize, 16 * sftp.maximumReadLength)

        try await sftp.createDirectory("/d")
        let data = Self.random(8 << 20)
        let file = try await sftp.openFile("/d/big.bin", flags: [.write, .create, .truncate])
        try await file.write(contentsOf: data)
        try await file.close()
        let entries = try await sftp.listDirectory("/d")
        XCTAssertEqual(entries.map(\.filename), ["big.bin"])
        let attributes = try await sftp.stat("/d/big.bin")
        XCTAssertEqual(attributes.size, UInt64(data.readableBytes))

        let reader = try await sftp.openFile("/d/big.bin", flags: .read)
        let back = try await reader.readAll()
        try await reader.close()
        XCTAssertEqual(SHA256.hash(data: back.readableBytesView), SHA256.hash(data: data.readableBytesView))
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: fileSystem.hostPath(for: "/d/big.bin")))
        XCTAssertEqual(SHA256.hash(data: onDisk), SHA256.hash(data: data.readableBytesView))
        await sftp.close()
        XCTAssertTrue(client.isConnected, "关 SFTP 只关通道")
    }

    /// 两端都用最小的包长（窗口只有 2 MiB）：大写入要靠可写性排队，64 个并发读要等窗口，结果照样对。
    func testSmallWindowsLargeWriteAndManyConcurrentReads() async throws {
        try await start(maximumPacketSize: 32_768)
        let client = try await connect(maximumPacketSize: 32_768)
        defer { Task { await client.close() } }
        let sftp = try await client.openSFTP()
        let data = Self.random(6 << 20)
        let file = try await sftp.openFile("/f", flags: [.read, .write, .create, .truncate])
        try await file.write(contentsOf: data, window: 64)
        let chunk = sftp.maximumReadLength
        let count = (data.readableBytes + chunk - 1) / chunk
        XCTAssertGreaterThanOrEqual(count, 24)
        let parts = try await withThrowingTaskGroup(of: (Int, ByteBuffer?).self) { group in
            for index in 0..<max(count, 64) {
                group.addTask {
                    let offset = (index % count) * chunk
                    return (index, try await file.read(from: UInt64(offset), length: chunk))
                }
            }
            var parts: [Int: ByteBuffer] = [:]
            for try await (index, part) in group where index < count { parts[index] = part }
            return parts
        }
        var joined = ByteBuffer()
        for index in 0..<count { var part = try XCTUnwrap(parts[index]); joined.writeBuffer(&part) }
        XCTAssertEqual(joined, data)
        try await file.close()
    }

    /// 连接掐断时，在途（服务端扣着不回）的请求全部以 `connectionClosed` 失败，不会挂住。
    func testDroppedConnectionFailsInFlightRequests() async throws {
        try await start()
        let client = try await connect()
        let sftp = try await client.openSFTP()
        let file = try await sftp.openFile("/f", flags: [.read, .write, .create])
        try await file.write(Self.random(4096), at: 0)
        faults.withholdResponses(of: .read)
        let results = try await withThrowingTaskGroup(of: (any Error)?.self) { group in
            for index in 0..<16 {
                group.addTask {
                    do {
                        _ = try await file.read(from: UInt64(index * 100), length: 100)
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            let faults = self.faults!
            let arrived = await Harness.eventually { faults.requestCount(of: .read) == 16 }
            XCTAssertTrue(arrived)
            await server.dropAllConnections()
            var errors: [(any Error)?] = []
            for try await error in group { errors.append(error) }
            return errors
        }
        XCTAssertEqual(results.count, 16)
        for error in results {
            XCTAssertEqual(error as? SFTPError, .connectionClosed, "\(String(describing: error))")
        }
        _ = await client.waitForDisconnect()
        XCTAssertFalse(sftp.isActive)
        await XCTAssertThrowsAsync(try await sftp.stat("/f")) { error in
            XCTAssertEqual(error as? SFTPError, .connectionClosed)
        }
    }

    /// 本端关整条连接：在途请求同样失败。
    func testClosingTheConnectionFailsInFlightRequests() async throws {
        try await start()
        let client = try await connect()
        let sftp = try await client.openSFTP()
        faults.withholdResponses(of: .stat)
        let pending = Task { try await sftp.stat("/") }
        let faults = self.faults!
        let arrived = await Harness.eventually { faults.requestCount(of: .stat) == 1 }
        XCTAssertTrue(arrived)
        await client.close()
        await XCTAssertThrowsAsync(try await pending.value) { error in
            XCTAssertEqual(error as? SFTPError, .connectionClosed)
        }
    }

    /// 服务端（subsystem）自己断开通道：在途请求失败，SSH 连接不受影响。
    func testServerDroppingTheSubsystemFailsPendingButKeepsTheConnection() async throws {
        try await start()
        let client = try await connect()
        defer { Task { await client.close() } }
        let sftp = try await client.openSFTP()
        faults.dropConnection(on: .stat)
        await XCTAssertThrowsAsync(try await sftp.stat("/")) { error in
            XCTAssertEqual(error as? SFTPError, .connectionClosed)
        }
        XCTAssertTrue(client.isConnected)
        let again = try await client.openSFTP()
        _ = try await again.realPath(".")
    }

    func testSubsystemRejected() async throws {
        server = try await SSHTestServer.start(Harness.serverConfiguration())
        let client = try await connect()
        defer { Task { await client.close() } }
        await XCTAssertThrowsAsync(try await client.openSFTP()) { error in
            guard case SSHChannelError.requestRejected(.subsystem("sftp")) = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(client.isConnected)
    }
}
