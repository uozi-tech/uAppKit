import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// 用**真实服务器**验证 OpenSSH 容器格式的 RSA 私钥能认证成功 —— 默认 SKIP。
///
/// 为什么非要真连一次：这个 bug 的全部表现都在协商出来的签名算法上（`ssh-rsa`
/// SHA-1 vs `rsa-sha2-512`），本地解码、签名、验签全都能过，只有服务端会拒。
/// OpenSSH 8.8+ 的服务端才会拒；对端太老则测不出东西。
///
/// 启用方式（环境变量，缺任一则 SKIP，不 FAIL）：
///   USSHKIT_TEST_RSA_HOST      — 目标主机
///   USSHKIT_TEST_RSA_USER      — 用户名
///   USSHKIT_TEST_RSA_KEY_PATH  — OpenSSH 容器格式（`BEGIN OPENSSH PRIVATE KEY`）的
///                                RSA 私钥路径
///   USSHKIT_TEST_RSA_PORT       — 可选，默认 22
///   USSHKIT_TEST_RSA_PASSPHRASE — 可选；给了就按带口令容器跑（覆盖 bcrypt_pbkdf +
///                                 AES-CTR 解密那条路）
final class OpenSSHRSALiveAuthTests: XCTestCase {

    private struct AcceptAllStore: HostKeyStore {
        func verify(_ hostKey: SSHHostKey) async throws -> SSHHostKeyVerification { .trusted }
        func remember(_ hostKey: SSHHostKey) async throws {}
    }

    func testOpenSSHContainerRSAAuthenticatesAgainstLiveServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["USSHKIT_TEST_RSA_HOST"],
              let user = env["USSHKIT_TEST_RSA_USER"],
              let keyPath = env["USSHKIT_TEST_RSA_KEY_PATH"] else {
            throw XCTSkip("设置 USSHKIT_TEST_RSA_HOST / _USER / _KEY_PATH 后运行")
        }
        let port = env["USSHKIT_TEST_RSA_PORT"].flatMap(Int.init) ?? 22
        let passphrase = env["USSHKIT_TEST_RSA_PASSPHRASE"].flatMap { $0.isEmpty ? nil : $0 }
        let pem = try String(contentsOfFile: keyPath, encoding: .utf8)

        // 前提校验：夹具必须真是 OpenSSH 容器格式，否则测的是 PEM 那条本就好的路。
        XCTAssertTrue(pem.contains("BEGIN OPENSSH PRIVATE KEY"),
                      "该测试要的是 OpenSSH 容器格式的 RSA 私钥")
        guard case .rsa = try PrivateKeyImporter.resolve(pem: pem, passphrase: passphrase) else {
            return XCTFail("私钥未走 rsa-sha2-512 分支")
        }

        let client = try await USSHKitIntegration.connect(
            endpoint: SSHEndpoint(host: host, port: port, username: user),
            credential: .privateKey(pem: pem, passphrase: passphrase),
            hostKeyStore: AcceptAllStore(),
            hostKeyPolicy: .insecureAcceptAll,
            connectTimeout: .seconds(20),
            approver: { _ in true })
        defer { Task { await client.close() } }

        let echoed = try await client.exec("echo usshkit-rsa-ok")
        XCTAssertTrue(echoed.contains("usshkit-rsa-ok"), echoed)
    }
}
