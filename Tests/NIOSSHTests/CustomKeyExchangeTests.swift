//===----------------------------------------------------------------------===//
//
// This file is part of uAppKit's patches to the SwiftNIO SSH project.
//
// Copyright (c) 2026 the uAppKit authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest

@testable import NIOSSH

// Toy custom key exchange methods. X25519 does the arithmetic, but the values travel the way finite-field
// Diffie-Hellman's do: as mpints (so leading zero bytes get stripped and a 0x00 is prepended when the high bit is
// set), hashed with a method-chosen hash function.

enum ToyKeyExchangeError: Error {
    case badPeerValue
}

let toyKeyExchangeInstances = NIOLockedValueBox(0)

private func x25519Secret(_ key: Curve25519.KeyAgreement.PrivateKey, peer: [UInt8]) throws -> [UInt8] {
    // mpint transport drops leading zeros: restore the fixed width.
    guard peer.count <= 32 else {
        throw ToyKeyExchangeError.badPeerValue
    }
    let padded = [UInt8](repeating: 0, count: 32 - peer.count) + peer
    let secret = try key.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: padded))
    return secret.withUnsafeBytes { Array($0) }
}

/// mpint-encoded values, SHA-256: the shape of `diffie-hellman-group14-sha256`.
struct ToyMPIntKeyExchange: NIOSSHKeyExchangeAlgorithmProtocol {
    typealias Hasher = SHA256
    static let keyExchangeAlgorithmNames: [Substring] = ["toy-dh-sha256@test.uappkit"]
    static let publicValueEncoding: NIOSSHKeyExchangePublicValueEncoding = .mpint

    private let key = Curve25519.KeyAgreement.PrivateKey()

    init() {
        toyKeyExchangeInstances.withLockedValue { $0 += 1 }
    }

    var publicValue: [UInt8] { Array(self.key.publicKey.rawRepresentation) }

    mutating func sharedSecret(peerPublicValue: [UInt8]) throws -> [UInt8] {
        try x25519Secret(self.key, peer: peerPublicValue)
    }
}

/// String-encoded values, SHA-1: a 20-byte hash, so 32-byte AES-256 keys need RFC 4253 §7.2 key extension.
struct ToySHA1KeyExchange: NIOSSHKeyExchangeAlgorithmProtocol {
    typealias Hasher = Insecure.SHA1
    static let keyExchangeAlgorithmNames: [Substring] = ["toy-ecdh-sha1@test.uappkit"]

    private let key = Curve25519.KeyAgreement.PrivateKey()

    init() {}

    var publicValue: [UInt8] { Array(self.key.publicKey.rawRepresentation) }

    mutating func sharedSecret(peerPublicValue: [UInt8]) throws -> [UInt8] {
        guard peerPublicValue.count == 32 else {
            throw ToyKeyExchangeError.badPeerValue
        }
        return try x25519Secret(self.key, peer: peerPublicValue)
    }
}

/// `curve25519-sha256` (RFC 8731) written against the extension point, to cross-check the seam's exchange hash and
/// key derivation against NIOSSH's own implementation. Never registered: the name is a built-in one.
struct SeamCurve25519KeyExchange: NIOSSHKeyExchangeAlgorithmProtocol {
    typealias Hasher = SHA256
    static let keyExchangeAlgorithmNames: [Substring] = ["curve25519-sha256"]

    private let key = Curve25519.KeyAgreement.PrivateKey()

    init() {}

    var publicValue: [UInt8] { Array(self.key.publicKey.rawRepresentation) }

    mutating func sharedSecret(peerPublicValue: [UInt8]) throws -> [UInt8] {
        guard peerPublicValue.count == 32 else {
            throw ToyKeyExchangeError.badPeerValue
        }
        return try x25519Secret(self.key, peer: peerPublicValue)
    }
}

/// Fixed values, for checking NIOSSH's mpint handling.
struct LeadingZerosKeyExchange: NIOSSHKeyExchangeAlgorithmProtocol {
    typealias Hasher = SHA256
    static let keyExchangeAlgorithmNames: [Substring] = ["leading-zeros@test.uappkit"]
    static let publicValueEncoding: NIOSSHKeyExchangePublicValueEncoding = .mpint
    init() {}
    var publicValue: [UInt8] { [0, 0, 0x7F] }
    mutating func sharedSecret(peerPublicValue: [UInt8]) throws -> [UInt8] { [1] }
}

struct HighBitKeyExchange: NIOSSHKeyExchangeAlgorithmProtocol {
    typealias Hasher = SHA256
    static let keyExchangeAlgorithmNames: [Substring] = ["high-bit@test.uappkit"]
    static let publicValueEncoding: NIOSSHKeyExchangePublicValueEncoding = .mpint
    init() {}
    var publicValue: [UInt8] { [0x80, 0x01] }
    mutating func sharedSecret(peerPublicValue: [UInt8]) throws -> [UInt8] { [1] }
}

struct ZeroSecretKeyExchange: NIOSSHKeyExchangeAlgorithmProtocol {
    typealias Hasher = SHA256
    static let keyExchangeAlgorithmNames: [Substring] = ["zero-secret@test.uappkit"]
    init() {}
    var publicValue: [UInt8] { [1] }
    mutating func sharedSecret(peerPublicValue: [UInt8]) throws -> [UInt8] { [0, 0] }
}

final class CustomKeyExchangeTests: CustomAlgorithmTestCase {
    private var channel: BackToBackEmbeddedChannel!
    private let ed25519 = Curve25519.Signing.PrivateKey()

    override func setUp() {
        super.setUp()
        NIOSSHAlgorithms._unregisterAllKeyExchangeAlgorithms()
        NIOSSHAlgorithms.register(keyExchangeAlgorithm: ToyMPIntKeyExchange.self)
        NIOSSHAlgorithms.register(keyExchangeAlgorithm: ToySHA1KeyExchange.self)
        self.channel = BackToBackEmbeddedChannel()
    }

    override func tearDown() {
        try? self.channel.finish()
        self.channel = nil
        NIOSSHAlgorithms._unregisterAllKeyExchangeAlgorithms()
        super.tearDown()
    }

    private static let toyMPInt = String(ToyMPIntKeyExchange.keyExchangeAlgorithmNames[0])
    private static let toySHA1 = String(ToySHA1KeyExchange.keyExchangeAlgorithmNames[0])

    private func connect(
        clientKeyExchange: [String],
        serverKeyExchange: [String],
        hostKeys: [NIOSSHPrivateKey]? = nil,
        hostKeyDelegate: NIOSSHClientServerAuthenticationDelegate = AcceptAllHostKeysDelegate()
    ) throws {
        var clientConfiguration = SSHClientConfiguration(
            userAuthDelegate: InfinitePasswordDelegate(),
            serverAuthDelegate: hostKeyDelegate
        )
        clientConfiguration.keyExchangeAlgorithms = clientKeyExchange
        var serverConfiguration = SSHServerConfiguration(
            hostKeys: hostKeys ?? [.init(ed25519Key: self.ed25519)],
            userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 0)
        )
        serverConfiguration.keyExchangeAlgorithms = serverKeyExchange

        let clientHandler = NIOSSHHandler(
            role: .client(clientConfiguration),
            allocator: self.channel.client.allocator,
            inboundChildChannelInitializer: nil
        )
        let serverHandler = NIOSSHHandler(role: .server(serverConfiguration), allocator: self.channel.server.allocator) {
            channel,
            _ in
            channel.eventLoop.makeSucceededVoidFuture()
        }
        try self.channel.client.pipeline.syncOperations.addHandler(clientHandler)
        try self.channel.server.pipeline.syncOperations.addHandler(serverHandler)
        try self.channel.activate()
    }

    /// Opens a session channel and reports whether it became active: the connection is usable end to end.
    private func openChannel() throws -> Bool {
        let promise = self.channel.client.eventLoop.makePromise(of: Channel.self)
        self.channel.clientSSHHandler?.createChannel(promise) { channel, _ in
            channel.eventLoop.makeSucceededVoidFuture()
        }
        try self.channel.interactInMemory()
        return (try? promise.futureResult.wait())?.isActive ?? false
    }

    // MARK: Configuration

    func testDefaultKeyExchangeAlgorithmsAreTheBuiltInOnes() {
        let client = SSHClientConfiguration(
            userAuthDelegate: InfinitePasswordDelegate(),
            serverAuthDelegate: AcceptAllHostKeysDelegate()
        )
        let server = SSHServerConfiguration(hostKeys: [], userAuthDelegate: DenyAllServerAuthDelegate())
        let builtIn = [
            "ecdh-sha2-nistp384", "ecdh-sha2-nistp256", "ecdh-sha2-nistp521", "curve25519-sha256",
            "curve25519-sha256@libssh.org",
        ]
        XCTAssertEqual(client.keyExchangeAlgorithms, builtIn)
        XCTAssertEqual(server.keyExchangeAlgorithms, builtIn)
    }

    func testOnlyConfiguredAndKnownMethodsAreOffered() {
        var configuration = SSHClientConfiguration(
            userAuthDelegate: InfinitePasswordDelegate(),
            serverAuthDelegate: AcceptAllHostKeysDelegate()
        )
        configuration.keyExchangeAlgorithms = [Self.toyMPInt, "not-registered@test.uappkit", "curve25519-sha256"]
        let client = SSHKeyExchangeStateMachine(
            allocator: ByteBufferAllocator(),
            loop: EmbeddedEventLoop(),
            role: .client(configuration),
            remoteVersion: Constants.version,
            protectionSchemes: [AES256GCMOpenSSHTransportProtection.self],
            previousSessionIdentifier: nil
        )
        XCTAssertEqual(
            client.createKeyExchangeMessage().keyExchangeAlgorithms,
            [Substring(Self.toyMPInt), "curve25519-sha256"]
        )
    }

    // MARK: Encoding

    func testMPIntPublicValuesAreCanonicallyEncoded() {
        let role = SSHConnectionRole.client(
            .init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())
        )
        let leadingZeros = CustomKeyExchange<LeadingZerosKeyExchange>(ourRole: role, previousSessionIdentifier: nil)
        XCTAssertEqual(
            Array(leadingZeros.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator()).publicKey.readableBytesView),
            [0x7F]
        )
        let highBit = CustomKeyExchange<HighBitKeyExchange>(ourRole: role, previousSessionIdentifier: nil)
        XCTAssertEqual(
            Array(highBit.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator()).publicKey.readableBytesView),
            [0x00, 0x80, 0x01]
        )
    }

    func testNegativePeerValuesAndZeroSecretsAreRejected() throws {
        let role = SSHConnectionRole.client(
            .init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())
        )
        let hostKey = NIOSSHPrivateKey(ed25519Key: self.ed25519)
        let signature = try hostKey.sign(digest: SHA256.hash(data: [UInt8]()))
        func reply(_ value: [UInt8]) -> SSHMessage.KeyExchangeECDHReplyMessage {
            .init(hostKey: hostKey.publicKey, publicKey: ByteBuffer(bytes: value), signature: signature)
        }
        let sizes = AES256GCMOpenSSHTransportProtection.keySizes

        var exchange = CustomKeyExchange<HighBitKeyExchange>(ourRole: role, previousSessionIdentifier: nil)
        var exchangeBytes = ByteBuffer()
        XCTAssertThrowsError(
            try exchange.receiveServerKeyExchangePayload(
                serverKeyExchangeMessage: reply([0x80, 0x01]),
                initialExchangeBytes: &exchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: sizes
            )
        ) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .invalidSSHMessage)
        }

        var zero = CustomKeyExchange<ZeroSecretKeyExchange>(ourRole: role, previousSessionIdentifier: nil)
        XCTAssertThrowsError(
            try zero.receiveServerKeyExchangePayload(
                serverKeyExchangeMessage: reply([0x01]),
                initialExchangeBytes: &exchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: sizes
            )
        ) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .weakSharedSecret)
        }
    }

    /// The seam computes H and the session keys exactly like NIOSSH's built-in ECDH: a seam-based client and a
    /// built-in server (and the other way round) agree on every key.
    func testSeamMatchesTheBuiltInCurve25519Implementation() throws {
        let clientRole = SSHConnectionRole.client(
            .init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())
        )
        let serverRole = SSHConnectionRole.server(
            .init(hostKeys: [.init(ed25519Key: self.ed25519)], userAuthDelegate: DenyAllServerAuthDelegate())
        )
        let hostKey = NIOSSHPrivateKey(ed25519Key: self.ed25519)
        let sizes = AES256GCMOpenSSHTransportProtection.keySizes
        var prefix = ByteBuffer()
        prefix.writeSSHString("client version".utf8)
        prefix.writeSSHString("server version".utf8)

        func run(
            client: inout some EllipticCurveKeyExchangeProtocol,
            server: inout some EllipticCurveKeyExchangeProtocol
        ) throws {
            var clientBytes = prefix
            var serverBytes = prefix
            let initMessage = client.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator())
            let (serverResult, reply) = try server.completeKeyExchangeServerSide(
                clientKeyExchangeMessage: initMessage,
                serverHostKey: hostKey,
                initialExchangeBytes: &serverBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: sizes
            )
            let clientResult = try client.receiveServerKeyExchangePayload(
                serverKeyExchangeMessage: reply,
                initialExchangeBytes: &clientBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: sizes
            )
            XCTAssertEqual(clientBytes, serverBytes, "exchange hash input")
            XCTAssertEqual(clientResult.sessionID, serverResult.sessionID)
            XCTAssertEqual(clientResult.keys.outboundEncryptionKey, serverResult.keys.inboundEncryptionKey)
            XCTAssertEqual(clientResult.keys.inboundEncryptionKey, serverResult.keys.outboundEncryptionKey)
            XCTAssertEqual(clientResult.keys.initialOutboundIV, serverResult.keys.initialInboundIV)
            XCTAssertEqual(clientResult.keys.initialInboundIV, serverResult.keys.initialOutboundIV)
            XCTAssertEqual(clientResult.keys.outboundMACKey, serverResult.keys.inboundMACKey)
            XCTAssertEqual(clientResult.keys.inboundMACKey, serverResult.keys.outboundMACKey)
        }

        var seamClient = CustomKeyExchange<SeamCurve25519KeyExchange>(ourRole: clientRole, previousSessionIdentifier: nil)
        var builtInServer = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: serverRole,
            previousSessionIdentifier: nil
        )
        try run(client: &seamClient, server: &builtInServer)

        var builtInClient = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: clientRole,
            previousSessionIdentifier: nil
        )
        var seamServer = CustomKeyExchange<SeamCurve25519KeyExchange>(ourRole: serverRole, previousSessionIdentifier: nil)
        try run(client: &builtInClient, server: &seamServer)
    }

    // MARK: End to end

    func testCustomKeyExchangeHandshakeAndRekey() throws {
        toyKeyExchangeInstances.withLockedValue { $0 = 0 }
        // Both sides prefer the custom method; the built-in ones remain as fallbacks.
        let methods = [Self.toyMPInt] + SSHKeyExchangeStateMachine.defaultKeyExchangeAlgorithms
        XCTAssertNoThrow(try self.connect(clientKeyExchange: methods, serverKeyExchange: methods))
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        XCTAssertEqual(toyKeyExchangeInstances.withLockedValue { $0 }, 2)

        // Rekey from both ends: a fresh exchange each time, keeping the session ID.
        XCTAssertNoThrow(try self.channel.clientSSHHandler!._rekey())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        XCTAssertNoThrow(try self.channel.serverSSHHandler!._rekey())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        XCTAssertEqual(toyKeyExchangeInstances.withLockedValue { $0 }, 6)
    }

    func testKeyExtensionForHashesShorterThanTheKey() throws {
        // AES-256-GCM is the first transport protection scheme: 32-byte keys from a 20-byte hash.
        XCTAssertNoThrow(try self.connect(clientKeyExchange: [Self.toySHA1], serverKeyExchange: [Self.toySHA1]))
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        XCTAssertNoThrow(try self.channel.clientSSHHandler!._rekey())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
    }

    func testCustomKeyExchangeWithCustomHostKey() throws {
        let recorder = RecordingHostKeyDelegate()
        XCTAssertNoThrow(
            try self.connect(
                clientKeyExchange: [Self.toyMPInt],
                serverKeyExchange: [Self.toyMPInt],
                hostKeys: [NIOSSHPrivateKey(custom: ToyAltPrivateKey(key: self.ed25519))],
                hostKeyDelegate: recorder
            )
        )
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        XCTAssertEqual(recorder.hostKeys, [NIOSSHPublicKey(custom: ToyPublicKey(key: self.ed25519.publicKey))])
    }

    func testUnregisteredKeyExchangeFailsNegotiationCleanly() throws {
        NIOSSHAlgorithms._unregisterAllKeyExchangeAlgorithms()
        XCTAssertNoThrow(try self.connect(clientKeyExchange: [Self.toyMPInt], serverKeyExchange: [Self.toyMPInt]))
        XCTAssertThrowsError(try self.channel.interactInMemory()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .keyExchangeNegotiationFailure)
        }
    }

    func testRegisteredButUnconfiguredKeyExchangeIsNotUsed() throws {
        // Only the client enables it: the default server configuration does not, so a built-in method is chosen.
        toyKeyExchangeInstances.withLockedValue { $0 = 0 }
        let client = [Self.toyMPInt] + SSHKeyExchangeStateMachine.defaultKeyExchangeAlgorithms
        XCTAssertNoThrow(
            try self.connect(
                clientKeyExchange: client,
                serverKeyExchange: SSHKeyExchangeStateMachine.defaultKeyExchangeAlgorithms
            )
        )
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        XCTAssertEqual(toyKeyExchangeInstances.withLockedValue { $0 }, 0)
    }
}
