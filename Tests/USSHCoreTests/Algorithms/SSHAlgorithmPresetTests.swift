import NIOCore
import NIOEmbedded
@testable import NIOSSH
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
        // 集合和 NIOSSH 的默认值相同，顺序是我们自己定的：curve25519 在前（NIOSSH 默认把 P-384 排最前）。
        XCTAssertEqual(preset.keyExchangeAlgorithms, Self.preferredBuiltInKeyExchangeAlgorithms)
        XCTAssertEqual(Set(preset.keyExchangeAlgorithms), Set(Self.nioDefaultKeyExchangeAlgorithms()))
        XCTAssertEqual(preset.keyExchangeAlgorithms.count, Self.nioDefaultKeyExchangeAlgorithms().count)
        XCTAssertEqual(preset.hostKeyAlgorithms, ["ssh-ed25519", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp521"])
        XCTAssertFalse(preset.allowsLegacyAlgorithms)
        // 默认构造的就是它（`SSHClient.Configuration` 的默认值）。
        XCTAssertEqual(names(SSHAlgorithms().transportProtectionSchemes), names(preset.transportProtectionSchemes))
        XCTAssertEqual(SSHAlgorithms().keyExchangeAlgorithms, preset.keyExchangeAlgorithms)
    }

    private static let aesCTR = ["aes256-ctr", "aes192-ctr", "aes128-ctr"]

    private static func ctr(_ macs: [String]) -> [String] {
        aesCTR.flatMap { cipher in macs.map { "\(cipher)+\($0)" } }
    }

    func testStandardPreset() {
        let preset = SSHAlgorithms.standard
        XCTAssertEqual(
            names(preset.transportProtectionSchemes),
            names(Constants.bundledTransportProtectionSchemes)
                + Self.ctr(["hmac-sha2-256-etm@openssh.com", "hmac-sha2-512-etm@openssh.com"])
                + Self.ctr(["hmac-sha2-256", "hmac-sha2-512"]))
        XCTAssertEqual(preset.keyExchangeAlgorithms, Self.preferredBuiltInKeyExchangeAlgorithms + [
            "diffie-hellman-group16-sha512", "diffie-hellman-group14-sha256",
        ])
        XCTAssertEqual(preset.hostKeyAlgorithms, SSHAlgorithms.builtInHostKeyAlgorithms + ["rsa-sha2-512", "rsa-sha2-256"])
        XCTAssertFalse(preset.allowsLegacyAlgorithms)
        XCTAssertFalse(preset.requiresLegacyRegistration)
        // AEAD 永远在最前：对端不支持 strict KEX 时，双方都有 AES-GCM 就协商不到 ETM。
        XCTAssertNil(preset.transportProtectionSchemes[0].macName)
        XCTAssertNil(preset.transportProtectionSchemes[1].macName)
    }

    func testLegacyCompatiblePreset() {
        let preset = SSHAlgorithms.legacyCompatible
        XCTAssertEqual(
            names(preset.transportProtectionSchemes),
            names(SSHAlgorithms.standard.transportProtectionSchemes)
                + Self.ctr(["hmac-sha1-etm@openssh.com"]) + Self.ctr(["hmac-sha1"]))
        XCTAssertEqual(preset.keyExchangeAlgorithms,
                       SSHAlgorithms.standard.keyExchangeAlgorithms + ["diffie-hellman-group14-sha1"])
        XCTAssertEqual(preset.hostKeyAlgorithms, SSHAlgorithms.standard.hostKeyAlgorithms + ["ssh-rsa"])
        XCTAssertTrue(preset.allowsLegacyAlgorithms)
        XCTAssertTrue(preset.requiresLegacyRegistration)
    }

    /// 预设里没有我们没实现、或不该默认用的东西。
    func testPresetsExcludeChaChaAndSHA1ByDefault() {
        for scheme in SSHAlgorithms.standard.transportProtectionSchemes {
            XCTAssertFalse(scheme.cipherName.contains("chacha20"))
            XCTAssertFalse((scheme.macName ?? "").contains("sha1"))
        }
        XCTAssertFalse(SSHAlgorithms.standard.keyExchangeAlgorithms.contains { $0.hasSuffix("sha1") })
    }

    func testLegacyEntriesAreDroppedUnlessAllowed() {
        var algorithms = SSHAlgorithms.legacyCompatible
        algorithms.allowsLegacyAlgorithms = false
        XCTAssertEqual(names(algorithms.effectiveTransportProtectionSchemes),
                       names(SSHAlgorithms.standard.transportProtectionSchemes))
        XCTAssertEqual(algorithms.effectiveKeyExchangeAlgorithms, SSHAlgorithms.standard.keyExchangeAlgorithms)
        XCTAssertEqual(algorithms.effectiveHostKeyAlgorithms, SSHAlgorithms.standard.hostKeyAlgorithms)
        XCTAssertFalse(algorithms.requiresLegacyRegistration)

        // ETM 形式的 SHA-1 同样被去掉。
        algorithms.transportProtectionSchemes = SSHTransportProtections.legacy
        XCTAssertTrue(algorithms.effectiveTransportProtectionSchemes.isEmpty)

        let allowed = SSHAlgorithms.legacyCompatible
        XCTAssertEqual(names(allowed.effectiveTransportProtectionSchemes), names(allowed.transportProtectionSchemes))
        XCTAssertEqual(allowed.effectiveKeyExchangeAlgorithms, allowed.keyExchangeAlgorithms)
        XCTAssertEqual(allowed.effectiveHostKeyAlgorithms, allowed.hostKeyAlgorithms)
    }

    // MARK: RSA 用户认证的尝试顺序

    func testRSAUserAuthPlanWithoutServerSigAlgs() {
        XCTAssertEqual(SSHRSAUserAuthenticationPlan.algorithms(allowsLegacyAlgorithms: false, serverSignatureAlgorithms: nil),
                       [.rsaSHA2_512, .rsaSHA2_256])
        XCTAssertEqual(SSHRSAUserAuthenticationPlan.algorithms(allowsLegacyAlgorithms: true, serverSignatureAlgorithms: nil),
                       [.rsaSHA2_512, .rsaSHA2_256, .sshRSA])
    }

    func testRSAUserAuthPlanWithServerSigAlgsUsesOnlyListedAlgorithms() {
        let plan = SSHRSAUserAuthenticationPlan.algorithms
        // OpenSSH 的典型宣告。
        let openSSH = ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256"]
        XCTAssertEqual(plan(false, openSSH), [.rsaSHA2_512, .rsaSHA2_256])
        XCTAssertEqual(plan(true, openSSH), [.rsaSHA2_512, .rsaSHA2_256])
        // 只支持 256：第一次就用 256，不再试 512。
        XCTAssertEqual(plan(false, ["rsa-sha2-256"]), [.rsaSHA2_256])
        // 只支持 ssh-rsa：允许旧算法时第一次就用它；不允许时不试 RSA。
        XCTAssertEqual(plan(true, ["ssh-rsa"]), [.sshRSA])
        XCTAssertEqual(plan(false, ["ssh-rsa"]), [])
        // 宣告了但没有 RSA：不试 RSA。
        XCTAssertEqual(plan(false, ["ssh-ed25519"]), [])
        XCTAssertEqual(plan(true, []), [])
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

    /// 认证结束后 `forgetCredentials()` 连同正在逐个算法尝试的 RSA 私钥一起丢掉：之后再被问也拿不出任何东西。
    func testRSAKeyMaterialIsDroppedWithTheOtherCredentials() throws {
        let key = try SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[1].pkcs1PEM)
        let loop = EmbeddedEventLoop()
        let delegate = SSHClientAuthDelegate(
            authentication: SSHAuthentication(username: "u", methods: [.rsaPrivateKey(key), .password("pw")]),
            allowsLegacyAlgorithms: true)
        let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.publicKey, .password], serverSignatureAlgorithms: nil,
                                        nextChallengePromise: first)
        XCTAssertNotNil(try first.futureResult.wait())
        delegate.forgetCredentials()
        let next = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.publicKey, .password], serverSignatureAlgorithms: nil,
                                        nextChallengePromise: next)
        XCTAssertNil(try next.futureResult.wait(), "rsa-sha2-256 与口令都不该再出现")
        XCTAssertEqual(delegate.attemptedRSAAlgorithms, [.rsaSHA2_512])
    }

    /// `server-sig-algs` 里没有 RSA：RSA 被跳过，列表用完时交给 NIOSSH 的 nil（唯一的用完路径），
    /// 失败详情里是服务器最后声明的方式与实际尝试过的（这里一个都没有）。
    func testSkippedRSAPlanEndsThroughTheSingleExhaustionPath() throws {
        let key = try SSHRSAPrivateKey(pemRepresentation: RSAFixtures.keys[1].pkcs1PEM)
        let loop = EmbeddedEventLoop()
        let delegate = SSHClientAuthDelegate(
            authentication: SSHAuthentication(username: "u", methods: [.rsaPrivateKey(key)]),
            allowsLegacyAlgorithms: false)
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.publicKey], serverSignatureAlgorithms: ["ssh-ed25519"],
                                        nextChallengePromise: promise)
        XCTAssertNil(try promise.futureResult.wait())
        XCTAssertEqual(delegate.failure.attemptedMethods, [])
        XCTAssertEqual(delegate.failure.remainingMethods, [.publicKey])
        XCTAssertEqual(delegate.attemptedRSAAlgorithms, [])
    }

    // MARK: 辅助

    /// 内置主机密钥算法与 NIOSSH 自己的一致（`builtInOnly` 必须恰好是它们）。
    func testBuiltInHostKeyAlgorithmsMatchNIOSSH() {
        XCTAssertEqual(SSHAlgorithms.builtInHostKeyAlgorithms,
                       SSHKeyExchangeStateMachine.supportedServerHostKeyAlgorithms.map(String.init))
    }

    /// 自带密钥交换算法里我们的先后：curve25519 优先，然后 P-256 / P-384 / P-521。
    private static let preferredBuiltInKeyExchangeAlgorithms = [
        "curve25519-sha256", "curve25519-sha256@libssh.org",
        "ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521",
    ]

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
