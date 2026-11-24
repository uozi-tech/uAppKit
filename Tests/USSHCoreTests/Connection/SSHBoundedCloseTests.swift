import Foundation
import NIOCore
import NIOSSH
@testable import USSHCore
import USSHTestServer
import XCTest

/// 关闭必须在有限时间内返回，不管对端怎样：链路被黑洞（`freezeAllConnections`：TCP 还在，服务端不读不写，包被悄悄
/// 丢掉）时，SFTP 客户端、exec / PTY 通道、连接（直连与经跳板机）的 `close()` 都在 `SSHClient.closeGracePeriod`
/// 附近返回，之后都报已关、在途请求都失败。链路正常时关闭照旧有序：通道先收到 CLOSE，连接后断。
final class SSHBoundedCloseTests: XCTestCase {
    /// 判定的上限：宽限 + 余量。
    private static let bound: Duration = SSHClient.closeGracePeriod + .seconds(1)

    private func sftpServer() async throws -> (SSHTestServer, SFTPLocalFileSystem) {
        let fileSystem = try SFTPLocalFileSystem.makeTemporary(prefix: "usshcore-close")
        var configuration = Harness.serverConfiguration(exec: .stream(
            chunk: ByteBuffer(string: "tick\n"), count: nil, interval: .milliseconds(50)))
        configuration.serveSFTP(fileSystem: fileSystem)
        return (try await SSHTestServer.start(configuration), fileSystem)
    }

    /// 计时跑 `body`；最多等 `cap` 就不等了（`body` 不响应取消时任务组会一直等它，所以用不结构化的任务赛跑），
    /// 返回用时。
    private func timed(cap: Duration = .seconds(20), _ body: @escaping @Sendable () async -> Void) async -> Duration {
        let start = ContinuousClock.now
        let once = OnceSignal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            once.set(continuation)
            Task { await body(); once.fire() }
            Task { try? await Task.sleep(for: cap); once.fire() }
        }
        return ContinuousClock.now - start
    }

    // MARK: - 黑洞

    func testSFTPClientCloseIsBoundedOnABlackholedLink() async throws {
        let (server, fileSystem) = try await sftpServer()
        defer { Task { await server.stop(); try? fileSystem.removeRoot() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }
        let sftp = try await client.openSFTP()
        await server.freezeAllConnections()
        let pending = Task { try await sftp.stat("/") }
        try await Task.sleep(for: .milliseconds(50))

        let elapsed = await timed { await sftp.close() }
        print("BOUNDED-CLOSE sftp-client \(elapsed)")
        XCTAssertLessThan(elapsed, Self.bound)
        XCTAssertFalse(sftp.isActive)
        let pendingEnded = await timed(cap: .seconds(3)) { _ = try? await pending.value }
        XCTAssertLessThan(pendingEnded, .seconds(1), "在途请求随关闭失败")
        await XCTAssertThrowsAsync(try await sftp.stat("/")) { error in
            XCTAssertEqual(error as? SFTPError, .connectionClosed, "\(error)")
        }
    }

    func testExecAndPTYCloseAreBoundedOnABlackholedLink() async throws {
        let (server, fileSystem) = try await sftpServer()
        defer { Task { await server.stop(); try? fileSystem.removeRoot() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }
        let exec = try await client.openExec("tail -f log")
        let shell = try await client.openShell(pty: SSHPseudoTerminal())
        await server.freezeAllConnections()
        let reader = Task { () -> Int in
            var chunks = 0
            for try await _ in exec.output { chunks += 1 }
            return chunks
        }
        let status = Task { await shell.exitStatus() }

        for (label, handle) in [("exec", exec), ("pty", shell)] {
            let elapsed = await timed { await handle.close() }
            print("BOUNDED-CLOSE \(label) \(elapsed)")
            XCTAssertLessThan(elapsed, Self.bound, label)
            XCTAssertFalse(handle.isActive, label)
        }
        // 读输出的与等退出状态的都结束了，不挂在已关的通道上。
        let ended = await timed(cap: .seconds(2)) {
            _ = try? await reader.value
            _ = await status.value
        }
        XCTAssertLessThan(ended, .seconds(1))
        let writeEnded = await timed(cap: .seconds(3)) {
            do {
                try await exec.write(ByteBuffer(string: "x"))
                XCTFail("wrote to a closed channel")
            } catch {}
        }
        XCTAssertLessThan(writeEnded, .seconds(1))
    }

    func testDirectConnectionCloseIsBoundedOnABlackholedLink() async throws {
        let (server, fileSystem) = try await sftpServer()
        defer { Task { await server.stop(); try? fileSystem.removeRoot() } }
        let client = try await Harness.connect(server)
        let sftp = try await client.openSFTP()
        await server.freezeAllConnections()
        let pending = Task { try await sftp.stat("/") }
        try await Task.sleep(for: .milliseconds(50))

        let elapsed = await timed { await client.close() }
        print("BOUNDED-CLOSE ssh-direct \(elapsed)")
        XCTAssertLessThan(elapsed, Self.bound)
        XCTAssertFalse(client.isConnected)
        guard case .localClose = client.disconnectReason else { return XCTFail("\(String(describing: client.disconnectReason))") }
        let pendingEnded = await timed(cap: .seconds(3)) { _ = try? await pending.value }
        XCTAssertLessThan(pendingEnded, .seconds(1), "在途请求随关闭失败")
        XCTAssertFalse(sftp.isActive)
    }

    /// 经跳板机的内层连接：外层被黑洞时内层的关闭（等外层对端回 CHANNEL_CLOSE）也在宽限内返回。
    func testJumpedConnectionCloseIsBoundedOnABlackholedLink() async throws {
        let bastion = try await SSHTestServer.start(Harness.serverConfiguration())
        let (target, fileSystem) = try await sftpServer()
        defer { Task { await bastion.stop(); await target.stop(); try? fileSystem.removeRoot() } }
        let outer = try await Harness.connect(bastion)
        defer { Task { await outer.close() } }
        let inner = try await outer.jump(to: target.host, port: target.port, configuration: Harness.clientConfiguration())
        let sftp = try await inner.openSFTP()
        await bastion.freezeAllConnections()

        let elapsed = await timed { await inner.close() }
        print("BOUNDED-CLOSE ssh-jumped \(elapsed)")
        XCTAssertLessThan(elapsed, Self.bound)
        XCTAssertFalse(inner.isConnected)
        XCTAssertFalse(sftp.isActive)
    }

    // MARK: - 正常链路

    /// 链路正常：SFTP 通道先关（服务端看到通道关闭），连接后断；用时远小于宽限。
    func testCloseOnAHealthyLinkIsOrderly() async throws {
        let (server, fileSystem) = try await sftpServer()
        defer { Task { await server.stop(); try? fileSystem.removeRoot() } }
        let client = try await Harness.connect(server)
        let sftp = try await client.openSFTP()
        let exec = try await client.openExec("tail -f log")

        let elapsed = await timed {
            await exec.close()
            await sftp.close()
            await client.close()
        }
        XCTAssertLessThan(elapsed, .milliseconds(500))
        try await server.waitForEvents { $0.closedConnections == 1 }
        let log = server.events.lifecycle
        print("BOUNDED-CLOSE healthy lifecycle \(log)")
        XCTAssertEqual(log.filter { $0 == "session-closed" }.count, 2, "\(log)")
        XCTAssertEqual(log.last, "connection-closed", "\(log)")
        XCTAssertEqual(log.firstIndex(of: "connection-closed"), log.count - 1, "两条通道都在连接断开之前关掉：\(log)")
    }
}

/// 只放行一次的信号。
private final class OnceSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        let now = lock.withLock { () -> Bool in
            if fired { return true }
            self.continuation = continuation
            return false
        }
        if now { continuation.resume() }
    }

    func fire() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !fired else { return nil }
            fired = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
