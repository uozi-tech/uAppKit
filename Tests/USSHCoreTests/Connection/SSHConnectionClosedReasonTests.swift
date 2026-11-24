import NIOCore
@testable import USSHCore
import USSHTestServer
import XCTest

/// `connectionClosedReason`：等断开原因落定时限时、不吞取消；全局请求的失败只在连接确实在断时才说成「断开」。
final class SSHConnectionClosedReasonTests: XCTestCase {
    private struct Unrelated: Error {}

    private func connected() async throws -> (SSHTestServer, SSHClient) {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        let client = try await Harness.connect(server)
        return (server, client)
    }

    /// 连接好好的：最多等半秒，按 fallback 算。
    func testWaitIsBoundedWhileTheConnectionIsUp() async throws {
        let (server, client) = try await connected()
        defer { Task { await client.close(); await server.stop() } }
        let start = ContinuousClock.now
        let reason = await client.connectionClosedReason(Unrelated())
        let elapsed = ContinuousClock.now - start
        guard case .transportError(let error) = reason, error is Unrelated else { return XCTFail("\(reason)") }
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    /// 等的时候任务被取消：立刻返回（以前 100 次 `try? Task.sleep` 吞掉取消，照样等满半秒）。
    func testCancellationEndsTheWaitImmediately() async throws {
        let (server, client) = try await connected()
        defer { Task { await client.close(); await server.stop() } }
        let task = Task { () -> (SSHDisconnectReason, Duration) in
            let start = ContinuousClock.now
            let reason = await client.connectionClosedReason(Unrelated())
            return (reason, ContinuousClock.now - start)
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let (reason, elapsed) = await task.value
        guard case .transportError = reason else { return XCTFail("\(reason)") }
        XCTAssertLessThan(elapsed, .milliseconds(300), "取消后不再等")
    }

    /// 等的时候连接真的断了：拿到真正的原因，不用等满。
    func testDisconnectDuringTheWaitIsReportedPromptly() async throws {
        let (server, client) = try await connected()
        let task = Task { () -> (SSHDisconnectReason, Duration) in
            let start = ContinuousClock.now
            let reason = await client.connectionClosedReason(Unrelated())
            return (reason, ContinuousClock.now - start)
        }
        try await Task.sleep(for: .milliseconds(30))
        await server.stop()
        let (reason, elapsed) = await task.value
        if case .transportError(let error) = reason, error is Unrelated { XCTFail("fell back instead of the real reason") }
        XCTAssertLessThan(elapsed, .milliseconds(450))
        await client.close()
    }

    /// 全局请求以别的错误失败、连接还在：原样交出去，不说成 `connectionClosed`；连接关了之后才是。
    func testGlobalRequestErrorIsOnlyConnectionClosedWhenClosing() async throws {
        let (server, client) = try await connected()
        defer { Task { await server.stop() } }
        let start = ContinuousClock.now
        let live = await client.globalRequestError(Unrelated())
        XCTAssertTrue(live is Unrelated, "\(live)")
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(100), "连接还在时不等")
        XCTAssertTrue(client.isConnected)

        await client.close()
        let closed = await client.globalRequestError(Unrelated())
        guard case SSHChannelError.connectionClosed(let reason) = closed, reason.isLocalClose else {
            return XCTFail("\(closed)")
        }
    }
}
