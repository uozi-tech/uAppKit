import Crypto
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
@testable import USSHCore
import USSHTestServer
import XCTest

/// 多步认证（RFC 4252 §5.1 的部分成功，NIOSSH 补丁 0014 把标志交给 delegate）：部分通过的方式不再提交，RSA 记下
/// 通过的算法、不换算法重递；下一个从配置里按顺序挑服务器还要的；配置里没有服务器还要的时，失败详情说清楚是「还要
/// 别的」而不是「被拒」。
final class SSHPartialSuccessTests: XCTestCase {
    static let rsaKey = try! SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[1].pkcs1PEM)
    static let ed25519Key = NIOSSHPrivateKey(ed25519Key: .init())

    private func server(
        keys: [NIOSSHPublicKey] = [NIOSSHPublicKey(rsaPublicKey: rsaKey.publicKey)],
        supportedMethods: NIOSSHAvailableUserAuthenticationMethods = [.password, .publicKey],
        acceptsLegacy: Bool = false,
        decision: @escaping @Sendable (SSHTestAuthAttempt) async -> SSHTestAuthDecision
    ) async throws -> SSHTestServer {
        var configuration = Harness.serverConfiguration(keys: keys)
        configuration.authentication.supportedMethods = supportedMethods
        configuration.authentication.decision = decision
        configuration.acceptsLegacyAlgorithms = acceptsLegacy
        return try await SSHTestServer.start(configuration)
    }

    private func configuration(_ methods: [SSHAuthenticationMethod], sha1Fallback: Bool = false) -> SSHClient.Configuration {
        var configuration = Harness.clientConfiguration(methods)
        configuration.algorithms = .standard
        configuration.allowsSHA1RSAUserAuthenticationFallback = sha1Fallback
        return configuration
    }

    private func kinds(_ server: SSHTestServer) -> [String] {
        server.events.authAttempts.map { attempt in
            switch attempt.method {
            case .password: return "password"
            case .publicKey: return attempt.rsaSignatureAlgorithm?.name ?? "publickey"
            default: return "other"
            }
        }
    }

    /// `rsa-sha2-512` 部分成功，再口令：一共两次，不拿同一把钥匙试 256，通过的算法记下来。
    func testRSASHA2512PartialSuccessThenPassword() async throws {
        let server = try await server { attempt in
            switch attempt.method {
            case .publicKey: return attempt.rsaSignatureAlgorithm == .rsaSHA2_512 ? .partialSuccess(remaining: [.publicKey, .password]) : .reject
            case .password: return .accept
            default: return .reject
            }
        }
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server, configuration([.rsaPrivateKey(Self.rsaKey), .password(Harness.password)]))
        defer { Task { await client.close() } }
        XCTAssertEqual(kinds(server), ["rsa-sha2-512", "password"])
        XCTAssertEqual(client.rsaUserAuthenticationAlgorithm, .rsaSHA2_512)
    }

    /// 没宣告 `server-sig-algs`、只认 `ssh-rsa` 的服务器上 `ssh-rsa` 那一步部分成功：记成 `ssh-rsa`（USSHKit 据此报
    /// 用上了 SHA-1 用户认证）。
    func testSSHRSAPartialSuccessIsRecordedAsLegacy() async throws {
        let server = try await server(acceptsLegacy: true) { attempt in
            switch attempt.method {
            case .publicKey: return attempt.rsaSignatureAlgorithm == .sshRSA ? .partialSuccess(remaining: .password) : .reject
            case .password: return .accept
            default: return .reject
            }
        }
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(
            server, configuration([.rsaPrivateKey(Self.rsaKey), .password(Harness.password)], sha1Fallback: true))
        defer { Task { await client.close() } }
        XCTAssertEqual(kinds(server), ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa", "password"])
        XCTAssertEqual(client.rsaUserAuthenticationAlgorithm, .sshRSA)
        XCTAssertTrue(client.rsaUserAuthenticationAlgorithm?.isLegacy == true)
    }

    /// 钥匙通过了，服务器还要口令，配置里没有：失败详情里的 `partiallyAcceptedMethods` 不为空（不是「钥匙被拒」）。
    func testPartialSuccessWithNothingConfiguredForTheRest() async throws {
        let server = try await server { attempt in
            if case .publicKey = attempt.method, attempt.rsaSignatureAlgorithm == .rsaSHA2_512 { return .partialSuccess(remaining: .password) }
            return .reject
        }
        defer { Task { await server.stop() } }
        do {
            _ = try await Harness.connect(server, configuration([.rsaPrivateKey(Self.rsaKey)]))
            XCTFail("应当失败")
        } catch SSHClientError.authenticationFailed(let failure) {
            XCTAssertEqual(failure.partiallyAcceptedMethods, [.publicKey])
            XCTAssertEqual(failure.attemptedMethods, [.publicKey])
            XCTAssertEqual(failure.remainingMethods, .password)
        }
        XCTAssertEqual(kinds(server), ["rsa-sha2-512"], "部分通过之后不再换算法重递同一把钥匙")
    }

    /// ed25519 钥匙 + 口令两步，配置把口令写在前面。服务器只在钥匙通过之后才收口令（像 `AuthenticationMethods
    /// publickey,password`）：口令先被拒；钥匙部分成功后从头挑，服务器这时要口令，口令再交一次、通过。
    func testEd25519ThenPasswordRescansTheConfiguredMethods() async throws {
        let keyPassed = NIOLockedValueBox(false)
        let server = try await server(keys: [Self.ed25519Key.publicKey]) { attempt in
            switch attempt.method {
            case .publicKey:
                keyPassed.withLockedValue { $0 = true }
                return .partialSuccess(remaining: .password)
            case .password: return keyPassed.withLockedValue { $0 } ? .accept : .reject
            default: return .reject
            }
        }
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server, configuration([.password(Harness.password), .privateKey(Self.ed25519Key)]))
        defer { Task { await client.close() } }
        XCTAssertEqual(kinds(server), ["password", "publickey", "password"])
        XCTAssertNil(client.rsaUserAuthenticationAlgorithm)
    }

    /// 部分通过的那把钥匙不会再交第二次；上一阶段被拒的钥匙在新阶段里还有一次机会（服务器上一阶段拒绝它，可能只是
    /// 那一步不该用它），按配置顺序排在口令前面。
    func testPartiallyAcceptedMethodIsNeverOfferedAgain() async throws {
        let other = NIOSSHPrivateKey(ed25519Key: .init())
        let server = try await server(keys: [Self.ed25519Key.publicKey]) { attempt in
            switch attempt.method {
            case .publicKey(let key): return key == Self.ed25519Key.publicKey ? .partialSuccess(remaining: [.publicKey, .password]) : .reject
            case .password: return .accept
            default: return .reject
            }
        }
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(
            server, configuration([.privateKey(other), .privateKey(Self.ed25519Key), .password(Harness.password)]))
        defer { Task { await client.close() } }
        let keys = server.events.authAttempts.compactMap { attempt -> NIOSSHPublicKey? in
            if case .publicKey(let key) = attempt.method { return key } else { return nil }
        }
        XCTAssertEqual(keys, [other.publicKey, Self.ed25519Key.publicKey, other.publicKey])
        XCTAssertEqual(kinds(server), ["publickey", "publickey", "publickey", "password"])
    }

    /// `.delegate` 方式收得到部分成功的标志，由它自己接着答。
    func testDelegateReceivesThePartialSuccessFlag() async throws {
        let server = try await server(keys: [Self.ed25519Key.publicKey]) { attempt in
            switch attempt.method {
            case .password: return .partialSuccess(remaining: .publicKey)
            case .publicKey: return .accept
            default: return .reject
            }
        }
        defer { Task { await server.stop() } }
        let delegate = RecordingDelegate(key: Self.ed25519Key)
        let client = try await Harness.connect(server, configuration([.delegate(delegate)]))
        defer { Task { await client.close() } }
        XCTAssertEqual(delegate.flags, [false, true])
        XCTAssertEqual(kinds(server), ["password", "publickey"])
    }
}

/// 第一次给口令，之后（部分成功时）给钥匙；记下每次收到的 partialSuccess。
private final class RecordingDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    let key: NIOSSHPrivateKey
    private let recorded = NIOLockedValueBox<[Bool]>([])
    var flags: [Bool] { recorded.withLockedValue { $0 } }

    init(key: NIOSSHPrivateKey) { self.key = key }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        XCTFail("应当调四参数的版本")
        nextChallengePromise.succeed(nil)
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                serverSignatureAlgorithms: [String]?, partialSuccess: Bool,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let count = recorded.withLockedValue { $0.append(partialSuccess); return $0.count }
        switch count {
        case 1:
            nextChallengePromise.succeed(.init(username: Harness.username, serviceName: "",
                                               offer: .password(.init(password: Harness.password))))
        case 2 where partialSuccess:
            nextChallengePromise.succeed(.init(username: Harness.username, serviceName: "",
                                               offer: .privateKey(.init(privateKey: key))))
        default:
            nextChallengePromise.succeed(nil)
        }
    }
}
