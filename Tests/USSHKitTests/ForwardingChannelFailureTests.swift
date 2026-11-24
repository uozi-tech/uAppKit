import XCTest
@_spi(uTermIntegration) @testable import USSHKit

final class ForwardingChannelFailureTests: XCTestCase {

    // MARK: - reason code 解析（NIOSSHError 诊断文本形如 "NIOSSHError.channelSetupRejected: Reason: 1 open failed"）

    func testAdministrativelyProhibitedReasonCodeParses() {
        XCTAssertEqual(
            SSHForwardingChannelFailure.rejectionKind(
                fromDiagnostics: "NIOSSHError.channelSetupRejected: Reason: 1 open failed"),
            .administrativelyProhibited
        )
    }

    func testConnectFailedReasonCodeParses() {
        XCTAssertEqual(
            SSHForwardingChannelFailure.rejectionKind(
                fromDiagnostics: "NIOSSHError.channelSetupRejected: Reason: 2 Connection refused"),
            .connectFailed
        )
    }

    func testResourceShortageReasonCodeParses() {
        XCTAssertEqual(
            SSHForwardingChannelFailure.rejectionKind(
                fromDiagnostics: "NIOSSHError.channelSetupRejected: Reason: 4 resource shortage"),
            .resourceShortage
        )
    }

    func testUnknownReasonCodeFallsBackToOther() {
        XCTAssertEqual(
            SSHForwardingChannelFailure.rejectionKind(
                fromDiagnostics: "NIOSSHError.channelSetupRejected: Reason: 3 unknown channel type"),
            .other
        )
        XCTAssertEqual(
            SSHForwardingChannelFailure.rejectionKind(fromDiagnostics: "no reason marker at all"),
            .other
        )
    }

    // MARK: - 错误归类

    func testForwardingTimeoutClassifiesAsTimeout() {
        let failure = SSHForwardingChannelFailure(classifying: ForwardingTimeoutError())
        XCTAssertEqual(failure.kind, .timeout)
        XCTAssertEqual(failure.detail, "开通道超时（上游无响应）")
    }

    func testUnrelatedErrorClassifiesAsOther() {
        struct Boom: Error {}
        let failure = SSHForwardingChannelFailure(classifying: Boom())
        XCTAssertEqual(failure.kind, .other)
    }

    // MARK: - 用户文案

    func testUserMessagesAreHumanReadable() {
        let timeout = SSHForwardingChannelFailure(kind: .timeout, detail: "d")
        XCTAssertTrue(timeout.userMessage(targetHost: "db.internal", targetPort: 5432).contains("db.internal:5432"))
        XCTAssertTrue(timeout.userMessage(targetHost: "db.internal", targetPort: 5432).contains("白名单"))

        let prohibited = SSHForwardingChannelFailure(kind: .administrativelyProhibited, detail: "d")
        XCTAssertTrue(prohibited.userMessage(targetHost: "db.internal", targetPort: 5432).contains("AllowTcpForwarding"))

        let connect = SSHForwardingChannelFailure(kind: .connectFailed, detail: "d")
        XCTAssertTrue(connect.userMessage(targetHost: "db.internal", targetPort: 5432).contains("无法连接目标 db.internal:5432"))
    }
}

/// 原因码由 USSHCore 解析好（`SSHChannelOpenFailure`）：「服务器不许转发」与「目标连不上」要分得开。
final class ForwardingChannelOpenFailureTests: XCTestCase {
    private func classify(_ code: UInt32) -> SSHForwardingChannelFailure {
        SSHForwardingChannelFailure(classifying: SSHChannelError.openRejected(
            SSHChannelOpenFailure(reasonCode: code, description: "desc")))
    }

    func testReasonCodesMapToKinds() {
        XCTAssertEqual(classify(1).kind, .administrativelyProhibited)
        XCTAssertEqual(classify(2).kind, .connectFailed)
        XCTAssertEqual(classify(4).kind, .resourceShortage)
        XCTAssertEqual(classify(3).kind, .other)
        XCTAssertEqual(classify(99).kind, .other)
    }

    func testProhibitedAndConnectFailedReadDifferently() {
        let prohibited = classify(1).userMessage(targetHost: "db", targetPort: 5432)
        let refused = classify(2).userMessage(targetHost: "db", targetPort: 5432)
        XCTAssertNotEqual(prohibited, refused)
        XCTAssertEqual(prohibited, String(localized: "跳板机拒绝端口转发（sshd 可能配置了 AllowTcpForwarding no）", bundle: ModuleBundle.bundle))
        XCTAssertEqual(refused, String(localized: "跳板机无法连接目标 \("db:5432")（连接被拒绝或地址不可达）", bundle: ModuleBundle.bundle))
        XCTAssertEqual(classify(4).userMessage(targetHost: "db", targetPort: 5432),
                       String(localized: "跳板机暂时打不开到 \("db:5432") 的通道（资源不足，可能是同时开着的通道太多）", bundle: ModuleBundle.bundle))
    }

    /// 通道层的文案同样按原因码。
    func testChannelErrorDescriptionsFollowTheReason() {
        func text(_ code: UInt32, _ description: String = "") -> String? {
            SSHChannelError.openRejected(SSHChannelOpenFailure(reasonCode: code, description: description)).errorDescription
        }
        XCTAssertEqual(text(1), String(localized: "服务器禁止打开这类通道（例如关闭了端口转发）", bundle: ModuleBundle.bundle))
        XCTAssertEqual(text(2), String(localized: "服务器连不上目标（连接被拒绝或地址不可达）", bundle: ModuleBundle.bundle))
        XCTAssertEqual(text(3), String(localized: "服务器不支持这类通道", bundle: ModuleBundle.bundle))
        XCTAssertEqual(text(4), String(localized: "服务器资源不足，暂时打不开新通道（例如超过了 MaxSessions）", bundle: ModuleBundle.bundle))
        XCTAssertEqual(text(77), String(localized: "服务器拒绝打开通道（原因码 \(String(77))）", bundle: ModuleBundle.bundle))
        XCTAssertEqual(text(77, "nope"), String(localized: "服务器拒绝打开通道（原因码 \(String(77))）：\(SSHPeerText.isolated("nope"))", bundle: ModuleBundle.bundle))
    }
}
