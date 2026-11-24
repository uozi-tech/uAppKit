import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

@testable import USSHCore

/// 三个预设的确切内容、旧算法的过滤、RSA 用户认证的尝试顺序。纯逻辑，不建连接。
final class SSHAlgorithmPresetTests: XCTestCase {
    private func names(_ schemes: [SSHTransportProtections.Scheme]) -> [String] {
        schemes.map { "\($0.cipherName)+\($0.macName ?? "aead")" }
    }

    func testBuiltInOnlyIsExactlyNIOSSHDefaults() {
        let preset = SSHAlgorithms.builtInOnly
        XCTAssertEqual(names(preset.transportProtectionSchemes), names(Constants.bundledTransportProtectionSchemes))
        XCTAssertEqual(preset.keyExchangeAlgorithms, Self.nioDefaultKeyExchangeAlgorithms())
        XCTAssertEqual(preset.rsaHostKeyAlgorithms, [])
        XCTAssertFalse(preset.allowsLegacyAlgorithms)
        // 默认构造的就是它（`SSHClient.Configuration` 的默认值）。
        XCTAssertEqual(names(SSHAlgorithms().transportProtectionSchemes), names(preset.transportProtectionSchemes))
        XCTAssertEqual(SSHAlgorithms().keyExchangeAlgorithms, preset.keyExchangeAlgorithms)
    }

    func testStandardPreset() {
        let preset = SSHAlgorithms.standard
        XCTAssertEqual(names(preset.transportProtectionSchemes), [
            "aes256-gcm@openssh.com+aead", "aes128-gcm@openssh.com+aead",
            "aes256-ctr+hmac-sha2-256", "aes192-ctr+hmac-sha2-256", "aes128-ctr+hmac-sha2-256",
        ].map { $0.replacingOccurrences(of: "+aead", with: "+" + (Self.bundledMACName ?? "aead")) })
        XCTAssertEqual(preset.keyExchangeAlgorithms, Self.nioDefaultKeyExchangeAlgorithms() + [
            "diffie-hellman-group16-sha512", "diffie-hellman-group14-sha256",
        ])
        XCTAssertEqual(preset.rsaHostKeyAlgorithms, [.rsaSHA2_512, .rsaSHA2_256])
        XCTAssertFalse(preset.allowsLegacyAlgorithms)
        XCTAssertFalse(preset.requiresLegacyRegistration)
    }

    func testLegacyCompatiblePreset() {
        let preset = SSHAlgorithms.legacyCompatible
        XCTAssertEqual(names(preset.transportProtectionSchemes), names(SSHAlgorithms.standard.transportProtectionSchemes) + [
            "aes256-ctr+hmac-sha1", "aes192-ctr+hmac-sha1", "aes128-ctr+hmac-sha1",
        ])
        XCTAssertEqual(preset.keyExchangeAlgorithms,
                       SSHAlgorithms.standard.keyExchangeAlgorithms + ["diffie-hellman-group14-sha1"])
        XCTAssertEqual(preset.rsaHostKeyAlgorithms, [.rsaSHA2_512, .rsaSHA2_256, .sshRSA])
        XCTAssertTrue(preset.allowsLegacyAlgorithms)
        XCTAssertTrue(preset.requiresLegacyRegistration)
    }

    /// 钉住「等 NIOSSH 补丁」的排除项。补丁（strict KEX、RFC 4253 §7.2 密钥加长）落地、放宽
    /// `SSHAlgorithmsPendingPatches` 时，有意地改这个测试。
    func testPendingPatchExclusions() {
        for preset in [SSHAlgorithms.standard, .legacyCompatible] {
            for scheme in preset.transportProtectionSchemes {
                let mac = scheme.macName ?? ""
                XCTAssertFalse(mac.hasSuffix("-etm@openssh.com"), "ETM 要等 strict KEX：\(mac)")
                XCTAssertNotEqual(mac, "hmac-sha2-512", "hmac-sha2-512 要等密钥加长补丁")
                XCTAssertFalse(scheme.cipherName.contains("chacha20"))
            }
        }
    }

    func testLegacyEntriesAreDroppedUnlessAllowed() {
        var algorithms = SSHAlgorithms.legacyCompatible
        algorithms.allowsLegacyAlgorithms = false
        XCTAssertEqual(names(algorithms.effectiveTransportProtectionSchemes),
                       names(SSHAlgorithms.standard.transportProtectionSchemes))
        XCTAssertEqual(algorithms.effectiveKeyExchangeAlgorithms, SSHAlgorithms.standard.keyExchangeAlgorithms)
        XCTAssertEqual(algorithms.effectiveRSAHostKeyAlgorithms, [.rsaSHA2_512, .rsaSHA2_256])
        XCTAssertFalse(algorithms.requiresLegacyRegistration)

        // ETM 形式的 SHA-1 同样被去掉。
        algorithms.transportProtectionSchemes = SSHTransportProtections.legacy
        XCTAssertTrue(algorithms.effectiveTransportProtectionSchemes.isEmpty)

        let allowed = SSHAlgorithms.legacyCompatible
        XCTAssertEqual(names(allowed.effectiveTransportProtectionSchemes), names(allowed.transportProtectionSchemes))
        XCTAssertEqual(allowed.effectiveKeyExchangeAlgorithms, allowed.keyExchangeAlgorithms)
        XCTAssertEqual(allowed.effectiveRSAHostKeyAlgorithms, [.rsaSHA2_512, .rsaSHA2_256, .sshRSA])
    }

    // MARK: RSA 用户认证的尝试顺序

    func testRSAUserAuthPlanWithoutServerSigAlgs() {
        XCTAssertEqual(SSHRSAUserAuthenticationPlan.algorithms(allowsLegacyAlgorithms: false, serverSignatureAlgorithms: nil),
                       [.rsaSHA2_512, .rsaSHA2_256])
        XCTAssertEqual(SSHRSAUserAuthenticationPlan.algorithms(allowsLegacyAlgorithms: true, serverSignatureAlgorithms: nil),
                       [.rsaSHA2_512, .rsaSHA2_256, .sshRSA])
    }

    func testRSAUserAuthPlanWithServerSigAlgsPicksBestSupportedFirst() {
        // OpenSSH 的典型宣告。
        let openSSH = ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256"]
        XCTAssertEqual(SSHRSAUserAuthenticationPlan.algorithms(allowsLegacyAlgorithms: false, serverSignatureAlgorithms: openSSH),
                       [.rsaSHA2_512, .rsaSHA2_256])
        // 只支持 256：第一次就用 256，512 放到后面。
        XCTAssertEqual(SSHRSAUserAuthenticationPlan.algorithms(allowsLegacyAlgorithms: false, serverSignatureAlgorithms: ["rsa-sha2-256"]),
                       [.rsaSHA2_256, .rsaSHA2_512])
        // 只支持 ssh-rsa：允许旧算法时第一次就用它；不允许时它根本不在候选里。
        XCTAssertEqual(SSHRSAUserAuthenticationPlan.algorithms(allowsLegacyAlgorithms: true, serverSignatureAlgorithms: ["ssh-rsa"]),
                       [.sshRSA, .rsaSHA2_512, .rsaSHA2_256])
        XCTAssertEqual(SSHRSAUserAuthenticationPlan.algorithms(allowsLegacyAlgorithms: false, serverSignatureAlgorithms: ["ssh-rsa"]),
                       [.rsaSHA2_512, .rsaSHA2_256])
        // 空列表（宣告了但不含 RSA）：按原顺序照样试。
        XCTAssertEqual(SSHRSAUserAuthenticationPlan.algorithms(allowsLegacyAlgorithms: false, serverSignatureAlgorithms: []),
                       [.rsaSHA2_512, .rsaSHA2_256])
    }

    /// 认证 delegate 按计划一次一个算法地出价，服务器不再接受公钥就跳到下一个方式。
    func testAuthDelegateOffersOneRSAAlgorithmPerAttempt() throws {
        let key = try SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[1].pkcs1PEM)
        let loop = EmbeddedEventLoop()
        for allowsLegacy in [false, true] {
            let delegate = SSHClientAuthDelegate(
                authentication: SSHAuthentication(username: "u", methods: [.rsaPrivateKey(key), .password("pw")]),
                allowsLegacyAlgorithms: allowsLegacy)
            var offers: [NIOSSHUserAuthenticationOffer?] = []
            for _ in 0..<(allowsLegacy ? 4 : 3) {
                let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
                delegate.nextAuthenticationType(availableMethods: [.publicKey, .password], nextChallengePromise: promise)
                offers.append(try promise.futureResult.wait())
            }
            let expected: [SSHRSASignatureAlgorithm] = allowsLegacy ? [.rsaSHA2_512, .rsaSHA2_256, .sshRSA] : [.rsaSHA2_512, .rsaSHA2_256]
            XCTAssertEqual(delegate.attemptedRSAAlgorithms, expected)
            guard case .password = offers.last??.offer else { return XCTFail("RSA 试完应该轮到口令") }
            XCTAssertEqual(delegate.attempted, Array(repeating: .publicKey, count: expected.count) + [.password])
        }

        // 第一次之后服务器不再接受 publickey：不再试 256，直接下一个方式。
        let delegate = SSHClientAuthDelegate(
            authentication: SSHAuthentication(username: "u", methods: [.rsaPrivateKey(key), .password("pw")]),
            allowsLegacyAlgorithms: false)
        let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.publicKey, .password], nextChallengePromise: first)
        _ = try first.futureResult.wait()
        let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.password], nextChallengePromise: second)
        guard case .password = try second.futureResult.wait()?.offer else { return XCTFail("应该轮到口令") }
        XCTAssertEqual(delegate.attemptedRSAAlgorithms, [.rsaSHA2_512])
    }

    // MARK: 辅助

    /// NIOSSH 客户端配置里 `keyExchangeAlgorithms` 的默认值。
    private static func nioDefaultKeyExchangeAlgorithms() -> [String] {
        SSHClientConfiguration(userAuthDelegate: NoAuth(), serverAuthDelegate: NoHostKey()).keyExchangeAlgorithms
    }

    private static let bundledMACName: String? = Constants.bundledTransportProtectionSchemes.first?.macName

    private final class NoAuth: NIOSSHClientUserAuthenticationDelegate {
        func nextAuthenticationType(
            availableMethods: NIOSSHAvailableUserAuthenticationMethods,
            nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
        ) {
            nextChallengePromise.succeed(nil)
        }
    }

    private final class NoHostKey: NIOSSHClientServerAuthenticationDelegate {
        func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
            validationCompletePromise.fail(ChannelError.operationUnsupported)
        }
    }
}
