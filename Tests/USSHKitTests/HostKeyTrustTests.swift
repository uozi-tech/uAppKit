import Crypto
import NIOSSH
import XCTest
@testable import USSHKit

/// 主机密钥策略矩阵：4 种策略 × 库里「已信任 / 没见过 / 变了」，直接调 `HostKeyTrust.validate`。
/// 建连时的时限（审批超时、审批期间握手不计时）见 `HostKeyTrustIntegrationTests`。
final class HostKeyTrustTests: XCTestCase {
    private let host = "db.example.com"
    private let port = 2222
    private let presented = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    private let previous = NIOSSHPrivateKey(ed25519Key: .init()).publicKey

    private enum Stored { case trusted, unknown, mismatch }

    private enum Outcome: Equatable {
        case accepted(remembered: Bool)
        case rejected
    }

    /// 只认 `hostKeyRejected`，取它的完整文案。
    private func message(_ error: (any Error)?) -> String? {
        guard case .hostKeyRejected? = error as? SSHConnectionError else { return nil }
        return (error as? SSHConnectionError)?.errorDescription
    }

    private func store(_ stored: Stored) -> MemoryHostKeyStore {
        switch stored {
        case .trusted:
            return MemoryHostKeyStore(known: [HostKeySerialization.serialize(presented, host: host, port: port)])
        case .unknown:
            return MemoryHostKeyStore()
        case .mismatch:
            return MemoryHostKeyStore(known: [HostKeySerialization.serialize(previous, host: host, port: port)])
        }
    }

    private func run(_ policy: SSHHostKeyPolicy, _ stored: Stored,
                     approve: Bool = true) async -> (Outcome, MemoryHostKeyStore, ApproverProbe, (any Error)?) {
        let store = store(stored)
        let probe = ApproverProbe(approve ? .approve : .reject)
        let trust = HostKeyTrust(host: host, port: port, store: store, policy: policy, approver: probe.approver)
        do {
            try await trust.validate(presented)
            return (.accepted(remembered: !store.remembered.isEmpty), store, probe, nil)
        } catch {
            return (.rejected, store, probe, error)
        }
    }

    func testPolicyMatrix() async {
        let expected: [(SSHHostKeyPolicy, Stored, Outcome, asks: Bool)] = [
            (.strict, .trusted, .accepted(remembered: false), false),
            (.strict, .unknown, .rejected, false),
            (.strict, .mismatch, .rejected, false),
            (.acceptNew, .trusted, .accepted(remembered: false), false),
            (.acceptNew, .unknown, .accepted(remembered: true), false),
            (.acceptNew, .mismatch, .rejected, false),
            (.ask, .trusted, .accepted(remembered: false), false),
            (.ask, .unknown, .accepted(remembered: true), true),
            (.ask, .mismatch, .accepted(remembered: true), true),
            (.insecureAcceptAll, .trusted, .accepted(remembered: false), false),
            (.insecureAcceptAll, .unknown, .accepted(remembered: true), false),
            (.insecureAcceptAll, .mismatch, .accepted(remembered: true), false),
        ]
        for (policy, stored, outcome, asks) in expected {
            let (actual, _, probe, error) = await run(policy, stored)
            XCTAssertEqual(actual, outcome, "\(policy) × \(stored)")
            XCTAssertEqual(!probe.challenges.isEmpty, asks, "\(policy) × \(stored) 是否问用户")
            if case .rejected = actual {
                guard case SSHConnectionError.hostKeyRejected = error! else {
                    return XCTFail("\(policy) × \(stored) 应抛 hostKeyRejected，实际 \(error!)")
                }
            }
        }
    }

    func testAskChallengesCarryKindAndFingerprints() async throws {
        let (_, _, unknownProbe, _) = await run(.ask, .unknown)
        let unknown = try XCTUnwrap(unknownProbe.challenges.first)
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertNil(unknown.previousFingerprint)
        XCTAssertEqual(unknown.hostKey, HostKeySerialization.serialize(presented, host: host, port: port))

        let (_, _, mismatchProbe, _) = await run(.ask, .mismatch)
        let mismatch = try XCTUnwrap(mismatchProbe.challenges.first)
        XCTAssertEqual(mismatch.kind, .mismatch)
        XCTAssertEqual(mismatch.previousFingerprint,
                       HostKeySerialization.serialize(previous, host: host, port: port).fingerprint)
    }

    func testAskRejectionIsNotRemembered() async {
        for stored in [Stored.unknown, .mismatch] {
            let (outcome, store, probe, error) = await run(.ask, stored, approve: false)
            XCTAssertEqual(outcome, .rejected, "\(stored)")
            XCTAssertEqual(probe.challenges.count, 1)
            XCTAssertTrue(store.remembered.isEmpty, "被拒的密钥不能记进库")
            let expected = stored == .unknown
                ? String(localized: "用户拒绝了未知主机密钥", bundle: ModuleBundle.bundle)
                : String(localized: "用户拒绝了变化的主机密钥", bundle: ModuleBundle.bundle)
            XCTAssertEqual(message(error), SSHConnectionError.hostKeyRejected(expected).errorDescription)
        }
    }

    func testRejectionMessagesNameHostAndFingerprints() async {
        let candidate = HostKeySerialization.serialize(presented, host: host, port: port)
        let (_, _, _, unknownError) = await run(.strict, .unknown)
        XCTAssertEqual(message(unknownError), SSHConnectionError.hostKeyRejected(String(
            localized: "未知主机 \(host):\(String(port))（\(candidate.fingerprint)）", bundle: ModuleBundle.bundle)).errorDescription)

        let old = HostKeySerialization.serialize(previous, host: host, port: port).fingerprint
        let (_, _, _, mismatchError) = await run(.acceptNew, .mismatch)
        XCTAssertEqual(message(mismatchError), SSHConnectionError.hostKeyRejected(String(
            localized: "主机密钥已变化：原 \(old)，现 \(candidate.fingerprint)", bundle: ModuleBundle.bundle)).errorDescription)
    }

    /// 库本身出错：原样抛出（建连时归成 `hostKeyRejected`，见集成测试）。
    func testStoreFailurePropagates() async {
        struct Broken: Error {}
        let trust = HostKeyTrust(host: host, port: port, store: MemoryHostKeyStore(verifyError: Broken()),
                                 policy: .insecureAcceptAll, approver: { _ in true })
        do {
            try await trust.validate(presented)
            XCTFail("库出错不能当成接受")
        } catch {
            XCTAssertTrue(error is Broken)
        }
    }

    /// 审批超时后回调被取消：即便确认框之后才点了「同意」，也不往库里写。
    func testLateApprovalAfterCancellationIsNotRemembered() async {
        let store = MemoryHostKeyStore()
        let trust = HostKeyTrust(host: host, port: port, store: store, policy: .ask, approver: { _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return true
        })
        let presented = self.presented
        let task = Task { try await trust.validate(presented) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            try await task.value
            XCTFail("被取消的审批不能算接受")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(store.remembered.isEmpty)
    }

    func testSerializationMatchesOpenSSH() {
        let key = HostKeySerialization.serialize(presented, host: host, port: port)
        let line = String(openSSHPublicKey: presented)
        XCTAssertEqual(key.keyType, "ssh-ed25519")
        XCTAssertEqual(key.keyBlob.base64EncodedString(), String(line.split(separator: " ")[1]))
        XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(key.fingerprint.hasSuffix("="))
    }
}
