import NIOCore
import NIOPosix
import XCTest
@testable import USSHKit

/// `SSHErrorText.describe` 的回归：桥接后只剩「错误 N」的值类型错误要给出可定位的文案。
///
/// 迁移前这里还有「主机密钥确认框停留 >10 秒 → `ChannelError.connectTimeout`」的回归（Citadel 写死的
/// login timer）。USSHCore 在等主机密钥回调时暂停握手计时，那条路不存在了；对应的行为测试在
/// `HostKeyTrustIntegrationTests.testSlowApprovalDoesNotTripHandshakeTimeout`，超时的文案在
/// `ErrorTextTests`。
final class ConnectFailureDescriptionTests: XCTestCase {
    func testChannelErrorsCarryTypeAndCase() {
        let text = SSHErrorText.describe(ChannelError.ioOnClosedChannel)
        XCTAssertTrue(text.contains("NIOCore.ChannelError"), text)
        XCTAssertFalse(text.contains("错误"), text)
    }

    func testNIOConnectionErrorNamesTargetAndErrno() async throws {
        // `NIOConnectionError` 的成员是 fileprivate(set)，只能靠真连一个没人监听的端口拿到。
        let group = MultiThreadedEventLoopGroup.singleton
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
            let text = SSHErrorText.describe(error)
            XCTAssertTrue(text.contains("127.0.0.1:\(port)"), text)
            XCTAssertTrue(text.contains("errno: \(ECONNREFUSED)"), text)
            XCTAssertFalse(text.contains("错误 1"), text)
            XCTAssertFalse(text.lowercased().contains("couldn"), text)
        }
    }

    func testLocalizedErrorsKeepTheirOwnDescription() {
        let error = SSHConnectionError.hostKeyRejected("用户拒绝")
        XCTAssertEqual(SSHErrorText.describe(error), error.errorDescription)
    }

    /// USSHCore 的错误经 USSHKit 补上了 `LocalizedError`，`localizedDescription` 不再是桥接的「错误 N」。
    func testCoreErrorsAreLocalized() {
        let errors: [any Error] = [
            SSHClientError.handshakeTimeout(.seconds(10)),
            SSHChannelError.channelClosed,
            SFTPError.connectionClosed,
            SSHCommandError.outputTooLarge(limit: 10),
            SSHRSAError.invalidPrivateKey,
        ]
        for error in errors {
            let text = error.localizedDescription
            XCTAssertEqual(text, (error as? LocalizedError)?.errorDescription, "\(error)")
            XCTAssertNil(text.range(of: #"错误\s*\d+|error \d+"#, options: .regularExpression), text)
        }
    }

    /// 等主机密钥回调的上限：只有 `.ask` 等人，给审批时限；其余策略只查一次库，给连接时限。
    func testHostKeyValidationTimeoutCoversApprovalOnlyWhenAsking() {
        let connect = Duration.seconds(30)
        let approval = Duration.seconds(180)
        XCTAssertEqual(
            HostKeyTrust.validationTimeout(policy: .ask, connectTimeout: connect, approvalTimeout: approval),
            approval
        )
        for policy in [SSHHostKeyPolicy.strict, .acceptNew, .insecureAcceptAll] {
            XCTAssertEqual(
                HostKeyTrust.validationTimeout(policy: policy, connectTimeout: connect, approvalTimeout: approval),
                connect,
                "\(policy)"
            )
        }
    }
}
