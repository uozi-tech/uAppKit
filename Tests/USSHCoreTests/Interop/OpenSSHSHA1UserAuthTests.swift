import Foundation
import NIOSSH
@testable import USSHCore
import XCTest

/// SHA-1 的 RSA 用户认证（`ssh-rsa` 签名）在**进程里没登记过旧算法**时也要能用：签名是本端写的，不该依赖
/// `registerLegacyAlgorithms()`。别的用例（测试服务端要接受 `ssh-rsa` 时）会在进程里登记旧算法，而登记不可撤销，
/// 所以这一条在一个新起的 xctest 进程里只跑它自己，对着本机真实的 sshd（`PubkeyAcceptedAlgorithms ssh-rsa`，
/// 它照样宣告 `server-sig-algs`，只列 `ssh-rsa`）。sshd 起不来时跳过。
final class OpenSSHSHA1UserAuthTests: XCTestCase {
    static let freshProcessVariable = "USSHCORE_TEST_FRESH_PROCESS"

    func testSHA1UserAuthWithoutLegacyRegistration() async throws {
        guard ProcessInfo.processInfo.environment[Self.freshProcessVariable] != nil else {
            try runInFreshProcess("USSHCoreTests.OpenSSHSHA1UserAuthTests/testSHA1UserAuthWithoutLegacyRegistration")
            return
        }
        XCTAssertFalse(SSHAlgorithms.legacyAlgorithmsRegistered, "新进程里不该有人登记过旧算法")
        let fixture = try await OpenSSHFixture.start(extraConfig: "PubkeyAcceptedAlgorithms ssh-rsa")
        defer { fixture.stop() }
        var configuration = fixture.configuration(methods: [.rsaPrivateKey(fixture.rsa2048Key)], algorithms: .standard)
        configuration.allowsSHA1RSAUserAuthenticationFallback = true
        let client = try await SSHClient.connect(host: "127.0.0.1", port: fixture.port, configuration: configuration)
        XCTAssertEqual(client.rsaUserAuthenticationAlgorithm, .sshRSA)
        let output = String(buffer: try await client.executeCommand("echo sha1-ok"))
        XCTAssertEqual(output, "sha1-ok\n")
        await client.close()
        XCTAssertFalse(SSHAlgorithms.legacyAlgorithmsRegistered, "SHA-1 用户签名是本端写的，不需要登记旧算法")
    }

    /// 用当前这个 xctest（`arguments[0]`）在新进程里只跑 `test` 一条。
    private func runInFreshProcess(_ test: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let bundle = Bundle(for: Self.self).bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["-XCTest", test, bundle]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.freshProcessVariable] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if output.contains("skipped") && !output.contains("error:") {
            throw XCTSkip("子进程里跳过了：\(output.suffix(400))")
        }
        XCTAssertEqual(process.terminationStatus, 0, "子进程失败：\(output.suffix(3000))", file: file, line: line)
        XCTAssertTrue(output.contains("Executed 1 test"), output.suffix(1000).description, file: file, line: line)
    }
}
