import Foundation
import NIOCore
import NIOSSH
import USSHTestServer
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// 内存里的主机密钥库：按 `host:port` 记一把密钥，记下每次 `remember`。
final class MemoryHostKeyStore: HostKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var known: [String: SSHHostKey]
    private var rememberedKeys: [SSHHostKey] = []
    private let verifyError: (any Error)?

    init(known: [SSHHostKey] = [], verifyError: (any Error)? = nil) {
        self.known = Dictionary(uniqueKeysWithValues: known.map { ("\($0.host):\($0.port)", $0) })
        self.verifyError = verifyError
    }

    var remembered: [SSHHostKey] { lock.withLock { rememberedKeys } }

    func verify(_ hostKey: SSHHostKey) async throws -> SSHHostKeyVerification {
        if let verifyError { throw verifyError }
        return lock.withLock {
            guard let stored = known["\(hostKey.host):\(hostKey.port)"] else { return .unknown }
            return stored.keyBlob == hostKey.keyBlob ? .trusted : .mismatch(previousFingerprint: stored.fingerprint)
        }
    }

    func remember(_ hostKey: SSHHostKey) async throws {
        lock.withLock {
            known["\(hostKey.host):\(hostKey.port)"] = hostKey
            rememberedKeys.append(hostKey)
        }
    }
}

/// 记下被问到的确认，按设定回答（可以先等一会儿，或永远不回答）。
final class ApproverProbe: @unchecked Sendable {
    enum Answer: Sendable {
        case approve
        case reject
        /// 等这么久再同意。
        case approveAfter(Duration)
        /// 一直不回答（直到所在任务被取消）。
        case never
    }

    private let lock = NSLock()
    private var recorded: [SSHHostKeyChallenge] = []
    private var cancelledFlag = false
    let answer: Answer

    init(_ answer: Answer) { self.answer = answer }

    var challenges: [SSHHostKeyChallenge] { lock.withLock { recorded } }
    /// `.never` 的等待是否被取消了（审批超时后 USSHCore 取消回调）。
    var wasCancelled: Bool { lock.withLock { cancelledFlag } }

    var approver: @Sendable (SSHHostKeyChallenge) async -> Bool {
        { [self] challenge in
            lock.withLock { recorded.append(challenge) }
            switch answer {
            case .approve:
                return true
            case .reject:
                return false
            case .approveAfter(let delay):
                try? await Task.sleep(for: delay)
                return true
            case .never:
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                lock.withLock { cancelledFlag = true }
                return false
            }
        }
    }
}

enum TestSSH {
    static let username = "tester"
    static let password = "hunter2"

    /// RSA 用户私钥要服务端（进程内的 `SSHTestServer`）认得 `ssh-rsa` / `rsa-sha2-*` 才能验签，
    /// 登记是进程级的，登记一次。
    // SSH-STACK-TODO(core): Track E 合进来以后改成登记 USSHCore 的 RSA 类型（或由测试服务端自己登记），
    // 垫片类型随 CoreShims.swift 一起删掉。
    static let registerRSA: Void = {
        NIOSSHAlgorithms.register(publicKey: ShimRSAPublicKey.self, signature: ShimRSASignature<ShimRSASHA512>.self)
        NIOSSHAlgorithms.register(publicKey: ShimRSAPublicKey.self, signature: ShimRSASignature<ShimRSASHA256>.self)
    }()

    /// 口令登录的服务端，exec 回 `echo`（`echo hello` → "hello\n"）。
    static func startServer(
        authentication: SSHTestAuthentication = SSHTestAuthentication(passwords: [username: password]),
        allowsDirectTCPIP: Bool = true,
        subsystems: [String: SSHTestSubsystemHandler] = [:],
        faults: SSHTestFaults = SSHTestFaults()
    ) async throws -> SSHTestServer {
        _ = registerRSA
        return try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: authentication,
            exec: .routes(["echo hello": .scripted(stdout: "hello\n")]),
            subsystems: subsystems,
            allowsDirectTCPIP: allowsDirectTCPIP,
            faults: faults
        ))
    }

    /// 服务端主机公钥在库里的样子。
    static func hostKey(of server: SSHTestServer, host: String? = nil, port: Int? = nil) -> SSHHostKey {
        HostKeySerialization.serialize(server.hostPublicKey, host: host ?? server.host, port: port ?? server.port)
    }

    static func endpoint(_ server: SSHTestServer, jumpHost: SSHJumpHost? = nil) -> SSHEndpoint {
        SSHEndpoint(host: server.host, port: server.port, username: username, jumpHost: jumpHost)
    }

    /// 用 `.insecureAcceptAll` 连一个测试服务端。
    static func connect(
        _ server: SSHTestServer,
        credential: SSHCredential = .password(password),
        store: MemoryHostKeyStore = MemoryHostKeyStore(),
        policy: SSHHostKeyPolicy = .insecureAcceptAll,
        connectTimeout: Duration = .seconds(10),
        approvalTimeout: Duration = .seconds(180),
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool = { _ in true },
        jumpHost: SSHJumpHost? = nil
    ) async throws -> ConnectedClient {
        try await USSHKitIntegration.connect(
            endpoint: endpoint(server, jumpHost: jumpHost),
            credential: credential,
            hostKeyStore: store,
            hostKeyPolicy: policy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver
        )
    }

    /// 私钥对应的 OpenSSH 公钥（交给测试服务端的 `authorizedKeys`）。
    static func publicKey(ofPrivateKey pem: String, passphrase: String? = nil) throws -> NIOSSHPublicKey {
        _ = registerRSA
        let parsed = try SSHPrivateKeyParser.parse(pem: pem, passphrase: passphrase)
        let material = try KeyImportInspector.inspect(rawText: pem, parsed: parsed, comment: "test")
        return try NIOSSHPublicKey(openSSHPublicKey: material.publicKey)
    }
}

extension XCTestCase {
    /// 断言抛出的是 `SSHConnectionError` 的某个 case，返回它的文字载荷。
    @discardableResult
    func assertConnectionError(
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ matches: (SSHConnectionError) -> String?
    ) async -> String? {
        do {
            try await body()
            XCTFail("应当失败", file: file, line: line)
            return nil
        } catch let error as SSHConnectionError {
            guard let message = matches(error) else {
                XCTFail("错误 case 不对：\(error)", file: file, line: line)
                return nil
            }
            return message
        } catch {
            XCTFail("应抛 SSHConnectionError，实际 \(String(reflecting: error))", file: file, line: line)
            return nil
        }
    }
}
