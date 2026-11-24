import NIOSSH
@testable import USSHCore
import XCTest

/// 对本机真实 sshd：限死某一类算法（主机密钥 / 密钥交换 / 加密 / MAC），我们没有交集时每次都报
/// `SSHClientError.noCommonAlgorithm`，带类别与 sshd 的报价。sshd 先发现时它发 SSH_MSG_DISCONNECT
/// （"no matching … found"）再关连接，我们先发现时 NIOSSH 报协商失败——两种顺序结果一样。sshd 起不来时整组跳过。
final class OpenSSHNegotiationFailureTests: XCTestCase {
    static let attempts = 5

    private func start(_ config: [String], rsaHostKeyBits: Int? = nil) async throws -> OpenSSHFixture {
        let fixture = try await OpenSSHFixture.start(
            extraConfig: config.joined(separator: "\n"), rsaHostKeyBits: rsaHostKeyBits, logLevel: "DEBUG1")
        addTeardownBlock { fixture.stop() }
        return fixture
    }

    private func failures(_ fixture: OpenSSHFixture, _ algorithms: SSHAlgorithms,
                          file: StaticString = #filePath, line: UInt = #line) async -> [SSHAlgorithmNegotiationFailure] {
        var result: [SSHAlgorithmNegotiationFailure] = []
        for attempt in 0..<Self.attempts {
            do {
                let client = try await fixture.connect(methods: [.privateKey(fixture.ed25519Key)], algorithms: algorithms)
                await client.close()
                XCTFail("第 \(attempt) 次居然连上了", file: file, line: line)
            } catch SSHClientError.noCommonAlgorithm(let failure) {
                result.append(failure)
            } catch {
                XCTFail("第 \(attempt) 次应是 noCommonAlgorithm，实际 \(String(reflecting: error))", file: file, line: line)
            }
        }
        XCTAssertEqual(result.count, Self.attempts, file: file, line: line)
        return result
    }

    /// `HostKeyAlgorithms ssh-rsa`：`.standard` 只有 SHA-2 的 RSA 主机密钥算法。sshd 先发现（它是服务端，按客户端
    /// 的列表挑），发 DISCONNECT 再关；它的 KEXINIT 早已到达，我们照样报得出是主机密钥。
    func testHostKeyMismatch() async throws {
        let fixture = try await start(["HostKeyAlgorithms ssh-rsa"], rsaHostKeyBits: 2048)
        for failure in await failures(fixture, .standard) {
            XCTAssertEqual(failure.category, .hostKey)
            XCTAssertEqual(failure.serverOffer, ["ssh-rsa"])
        }
        // 这里不核对 sshd 自己的日志：客户端从对方的 KEXINIT 就能下结论并挂断，sshd 这时可能还没来得及
        // 记下「no matching host key type found」（约七次里有一次只记到连接被关）。结论是否正确由上面的
        // 类别与服务器报的列表保证——它们和 sshd 的 `HostKeyAlgorithms ssh-rsa` 配置一致。
    }

    func testKeyExchangeMismatch() async throws {
        let fixture = try await start(["KexAlgorithms diffie-hellman-group14-sha1"])
        for failure in await failures(fixture, .standard) {
            XCTAssertEqual(failure.category, .keyExchange)
            XCTAssertEqual(failure.serverOffer.filter { !$0.hasPrefix("kex-strict") && !$0.hasPrefix("ext-info") },
                           ["diffie-hellman-group14-sha1"])
        }
    }

    func testEncryptionMismatch() async throws {
        let fixture = try await start(["Ciphers aes128-cbc"])
        for failure in await failures(fixture, .standard) {
            XCTAssertEqual(failure.category, .encryption)
            XCTAssertEqual(failure.serverOffer, ["aes128-cbc"])
        }
    }

    /// sshd 对 AEAD 不看 MAC，NIOSSH 却要求 MAC 名字有交集：这里是我们先发现（sshd 那边本来会接受）。
    func testMACMismatch() async throws {
        let fixture = try await start(["MACs hmac-md5"])
        for failure in await failures(fixture, .builtInOnly) {
            XCTAssertEqual(failure.category, .mac)
            XCTAssertEqual(failure.serverOffer, ["hmac-md5"])
        }
    }
}
