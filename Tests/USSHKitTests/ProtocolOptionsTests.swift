@preconcurrency import Citadel
import NIOCore
import XCTest
@testable import USSHKit

/// `protocolOptions` 透传的回归。
///
/// 它决定 NIOSSH 子通道的初始窗口（`SSHChannelMultiplexer` 用
/// `targetWindowSize: Int32(maximumPacketSize)` 建 child channel），默认 128 KiB
/// 卡住 SFTP 大文件下载的吞吐。跳板机场景**两跳都得设**：内层连接的流量全装在外层
/// 那条 direct-tcpip 子通道里，外层不放大内层就白设——所以这里专门盯内层 hop。
final class ProtocolOptionsTests: XCTestCase {
    private struct StubHostKeyStore: HostKeyStore {
        func verify(_ hostKey: SSHHostKey) async throws -> SSHHostKeyVerification { .trusted }
        func remember(_ hostKey: SSHHostKey) async throws {}
    }

    private func makeSettings(
        protocolOptions: Set<SSHProtocolOption>,
        policy: SSHHostKeyPolicy = .acceptNew
    ) -> SSHClientSettings {
        SSHClientFactory.makeJumpSettings(
            endpoint: SSHEndpoint(host: "db.example.com", port: 2222, username: "database"),
            authenticationMethod: .passwordBased(username: "database", password: "secret"),
            hostKeyStore: StubHostKeyStore(),
            hostKeyPolicy: policy,
            connectTimeout: .seconds(15),
            approvalTimeout: .seconds(180),
            approver: { _ in true },
            protocolOptions: protocolOptions
        )
    }

    func testJumpSettingsCarryProtocolOptions() {
        let options: Set<SSHProtocolOption> = [.maximumPacketSize(1 << 20)]
        let settings = makeSettings(protocolOptions: options)

        XCTAssertEqual(settings.protocolOptions, options)
        XCTAssertEqual(settings.host, "db.example.com")
        XCTAssertEqual(settings.port, 2222)
    }

    func testJumpSettingsDefaultToEmptyProtocolOptions() {
        XCTAssertTrue(makeSettings(protocolOptions: []).protocolOptions.isEmpty)
    }

    /// 抽 `makeJumpSettings` 时别把既有的超时设置漏掉。
    func testJumpSettingsStillCarryTimeouts() {
        let settings = makeSettings(protocolOptions: [], policy: .ask)

        XCTAssertEqual(settings.connectTimeout, .seconds(15))
        // `.ask` 下 loginTimeout = connectTimeout + approvalTimeout。
        XCTAssertEqual(settings.loginTimeout, .seconds(195))
    }

    /// 1 MiB 必须落在 NIOSSH `SSHPacketParser` 的两条 precondition 之内
    /// （`>= 32768` 且 `<= 1 << 24`）——越界是进程 abort，不是抛错。
    func testIntendedWindowSizeIsWithinNIOSSHBounds() {
        let oneMiB = 1 << 20
        XCTAssertGreaterThanOrEqual(oneMiB, 32_768)
        XCTAssertLessThanOrEqual(oneMiB, 1 << 24)
    }
}
