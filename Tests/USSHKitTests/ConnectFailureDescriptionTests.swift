import NIOCore
import NIOPosix
import XCTest
@testable import USSHKit

/// `SSHClientFactory.describe` / `loginTimeout` 的回归：
/// 修的是「主机密钥确认弹层停留 >10 秒 → 连接以 `ChannelError.connectTimeout` 失败、
/// 文案只有『NIOCore.ChannelError 错误 0』」这条路。
final class ConnectFailureDescriptionTests: XCTestCase {
    func testChannelErrorConnectTimeoutIsLocatable() {
        let text = SSHClientFactory.describe(ChannelError.connectTimeout(.seconds(10)))
        XCTAssertTrue(text.contains("10 秒"), text)
        XCTAssertTrue(text.contains("connectTimeout"), text)
        XCTAssertFalse(text.contains("错误 0"), text)
        XCTAssertFalse(text.lowercased().contains("couldn"), text)
    }

    func testOtherChannelErrorsCarryTypeAndCase() {
        let text = SSHClientFactory.describe(ChannelError.ioOnClosedChannel)
        XCTAssertTrue(text.contains("NIOCore.ChannelError"), text)
        XCTAssertFalse(text.contains("错误"), text)
    }

    func testNIOConnectionErrorNamesTargetAndErrno() async throws {
        // `NIOConnectionError` 的成员是 fileprivate(set)，只能靠真连一个没人监听的端口拿到。
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let listener = try await ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = listener.localAddress!.port!
        try await listener.close()

        do {
            let channel = try await ClientBootstrap(group: group)
                .connect(host: "127.0.0.1", port: port).get()
            try? await channel.close()
            XCTFail("connect to a closed port unexpectedly succeeded")
        } catch {
            XCTAssertTrue(error is NIOConnectionError, String(reflecting: error))
            let text = SSHClientFactory.describe(error)
            XCTAssertTrue(text.contains("127.0.0.1:\(port)"), text)
            XCTAssertTrue(text.contains("errno: \(ECONNREFUSED)"), text)
            XCTAssertFalse(text.contains("错误 1"), text)
            XCTAssertFalse(text.lowercased().contains("couldn"), text)
        }
    }

    func testLocalizedErrorsKeepTheirOwnDescription() {
        let text = SSHClientFactory.describe(SSHConnectionError.hostKeyRejected("用户拒绝"))
        XCTAssertEqual(text, "SSH 主机密钥被拒绝：用户拒绝")
    }

    func testLoginTimeoutCoversHostKeyApprovalOnlyWhenAsking() {
        let connect = Duration.seconds(30)
        let approval = Duration.seconds(180)
        XCTAssertEqual(
            SSHClientFactory.loginTimeout(connectTimeout: connect, approvalTimeout: approval, policy: .ask),
            .seconds(210)
        )
        for policy in [SSHHostKeyPolicy.strict, .acceptNew, .insecureAcceptAll] {
            XCTAssertEqual(
                SSHClientFactory.loginTimeout(connectTimeout: connect, approvalTimeout: approval, policy: policy),
                connect,
                "\(policy)"
            )
        }
    }
}
