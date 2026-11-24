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
import NIOCore
import NIOEmbedded
import XCTest

@testable import NIOSSH

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A test-only transport protection that needs more key material than any built-in key exchange hash produces
/// (80-byte encryption keys, 64-byte MAC keys, 48-byte IVs) and proves both ends derived the same keys: packets
/// are sent in clear, but every packet carries HMAC-SHA256(MAC key, seq || encryption key || IV || packet).
///
/// It also records the sequence numbers NIOSSH hands it, in order, for the strict key exchange tests.
final class KeyCheckingTransportProtection: NIOSSHTransportProtection {
    enum Event: Equatable {
        case outbound(UInt32)
        case inbound(UInt32)
    }

    enum KeyCheckError: Error {
        case badMAC
        case malformed
    }

    /// Every instance NIOSSH created, in creation order (one per side per key exchange).
    nonisolated(unsafe) static var instances: [KeyCheckingTransportProtection] = []

    static let cipherName = "keycheck@test.uappkit"
    static let macName: String? = "hmac-keycheck@test.uappkit"
    static let cipherBlockSize = 8
    static let keySizes = ExpectedKeySizes(ivSize: 48, encryptionKeySize: 80, macKeySize: 64)

    let macBytes = 32
    let lengthEncrypted = true

    private(set) var keys: NIOSSHSessionKeys
    private(set) var events: [Event] = []

    init(initialKeys: NIOSSHSessionKeys) throws {
        guard initialKeys.outboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
            initialKeys.inboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
            initialKeys.outboundMACKey.bitCount == Self.keySizes.macKeySize * 8,
            initialKeys.inboundMACKey.bitCount == Self.keySizes.macKeySize * 8,
            initialKeys.initialOutboundIV.count == Self.keySizes.ivSize,
            initialKeys.initialInboundIV.count == Self.keySizes.ivSize
        else {
            throw NIOSSHError.invalidKeySize
        }
        self.keys = initialKeys
        Self.instances.append(self)
    }

    func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        self.keys = newKeys
    }

    func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        // Cleartext: the length is already readable.
    }

    func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        self.events.append(.inbound(sequenceNumber))
        guard var packet = source.readSlice(length: source.readableBytes - self.macBytes),
            let tag = source.readSlice(length: self.macBytes)
        else {
            throw KeyCheckError.malformed
        }
        let expected = Self.tag(
            sequenceNumber: sequenceNumber,
            encryptionKey: self.keys.inboundEncryptionKey,
            iv: self.keys.initialInboundIV,
            macKey: self.keys.inboundMACKey,
            packet: packet
        )
        guard tag.readableBytesView.elementsEqual(expected) else {
            throw KeyCheckError.badMAC
        }
        packet.moveReaderIndex(forwardBy: 4)
        guard let paddingLength = packet.readInteger(as: UInt8.self),
            let content = packet.readSlice(length: packet.readableBytes - Int(paddingLength))
        else {
            throw KeyCheckError.malformed
        }
        return content
    }

    func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        self.events.append(.outbound(sequenceNumber))
        let tag = Self.tag(
            sequenceNumber: sequenceNumber,
            encryptionKey: self.keys.outboundEncryptionKey,
            iv: self.keys.initialOutboundIV,
            macKey: self.keys.outboundMACKey,
            packet: destination
        )
        destination.writeBytes(tag)
    }

    private static func tag(
        sequenceNumber: UInt32,
        encryptionKey: SymmetricKey,
        iv: [UInt8],
        macKey: SymmetricKey,
        packet: ByteBuffer
    ) -> [UInt8] {
        var hmac = HMAC<SHA256>(key: macKey)
        var seq = ByteBuffer()
        seq.writeInteger(sequenceNumber)
        hmac.update(data: seq.readableBytesView)
        encryptionKey.withUnsafeBytes { hmac.update(data: Array($0)) }
        hmac.update(data: iv)
        hmac.update(data: packet.readableBytesView)
        return Array(hmac.finalize())
    }
}

final class KeyDerivationTests: XCTestCase {
    /// RFC 4253 §7.2 extension, checked against a vector computed independently (Python's hashlib) and against
    /// a from-scratch recomputation.
    func testDerivedKeyExtensionKnownAnswer() {
        var encodedSecret = ByteBuffer()
        encodedSecret.writePositiveMPInt([0x81, 0x02, 0x03])
        XCTAssertEqual(Array(encodedSecret.readableBytesView), [0, 0, 0, 4, 0x00, 0x81, 0x02, 0x03])
        let exchangeHash = Array(SHA256.hash(data: Array("exchange hash".utf8)))
        let sessionID = ByteBuffer(bytes: SHA256.hash(data: Array("session id".utf8)))

        var base = SHA256()
        base.update(data: encodedSecret.readableBytesView)
        base.update(data: exchangeHash)

        let derived = base.sshDerivedKey(discriminatorByte: UInt8(ascii: "C"), sessionID: sessionID, length: 80)
        // python3: K1 = sha256(K+H+b'C'+sid); K2 = sha256(K+H+K1); K3 = sha256(K+H+K1+K2); (K1+K2+K3)[:80]
        let expected =
            "3d353a1dbaec44ff675a61e763d70b231526e045d689632f0aee692b7d7734c8"
            + "139172b0f43a967b2a166a5f9ba962e2ae8f273aa135593e56b395ecd643fec5"
            + "eaaa29eb16e2c46174f8cc73de07d2dc"
        let hexDigits = Array("0123456789abcdef")
        XCTAssertEqual(String(derived.flatMap { [hexDigits[Int($0 >> 4)], hexDigits[Int($0 & 0xF)]] }), expected)

        // The same, computed from scratch.
        let prefix = Array(encodedSecret.readableBytesView) + exchangeHash
        let k1 = Array(SHA256.hash(data: prefix + [UInt8(ascii: "C")] + Array(sessionID.readableBytesView)))
        let k2 = Array(SHA256.hash(data: prefix + k1))
        let k3 = Array(SHA256.hash(data: prefix + k1 + k2))
        XCTAssertEqual(derived, Array((k1 + k2 + k3).prefix(80)))

        // Shorter keys are a prefix of the first block, as before.
        XCTAssertEqual(
            base.sshDerivedKey(discriminatorByte: UInt8(ascii: "C"), sessionID: sessionID, length: 16),
            Array(k1.prefix(16))
        )
        XCTAssertEqual(
            base.sshDerivedKey(discriminatorByte: UInt8(ascii: "C"), sessionID: sessionID, length: 32),
            k1
        )
    }

    /// Every built-in key exchange derives keys longer than its hash, identically on both ends.
    func testEveryBuiltInKeyExchangeDerivesLongKeys() throws {
        let clientRole = SSHConnectionRole.client(
            .init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())
        )
        let serverRole = SSHConnectionRole.server(
            .init(hostKeys: [.init(ed25519Key: .init())], userAuthDelegate: DenyAllServerAuthDelegate())
        )
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())

        func run<Key: ECDHCompatiblePrivateKey>(_: Key.Type) throws {
            var client = EllipticCurveKeyExchange<Key>(ourRole: clientRole, previousSessionIdentifier: nil)
            var server = EllipticCurveKeyExchange<Key>(ourRole: serverRole, previousSessionIdentifier: nil)
            var clientBytes = ByteBuffer()
            var serverBytes = ByteBuffer()
            let (serverResult, reply) = try server.completeKeyExchangeServerSide(
                clientKeyExchangeMessage: client.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator()),
                serverHostKey: hostKey,
                initialExchangeBytes: &serverBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: KeyCheckingTransportProtection.keySizes
            )
            let clientResult = try client.receiveServerKeyExchangePayload(
                serverKeyExchangeMessage: reply,
                initialExchangeBytes: &clientBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: KeyCheckingTransportProtection.keySizes
            )
            let sizes = KeyCheckingTransportProtection.keySizes
            XCTAssertEqual(clientResult.keys.initialOutboundIV.count, sizes.ivSize)
            XCTAssertEqual(clientResult.keys.outboundEncryptionKey.bitCount, sizes.encryptionKeySize * 8)
            XCTAssertEqual(clientResult.keys.outboundMACKey.bitCount, sizes.macKeySize * 8)
            XCTAssertEqual(clientResult.keys.initialOutboundIV, serverResult.keys.initialInboundIV)
            XCTAssertEqual(clientResult.keys.initialInboundIV, serverResult.keys.initialOutboundIV)
            XCTAssertEqual(clientResult.keys.outboundEncryptionKey, serverResult.keys.inboundEncryptionKey)
            XCTAssertEqual(clientResult.keys.inboundEncryptionKey, serverResult.keys.outboundEncryptionKey)
            XCTAssertEqual(clientResult.keys.outboundMACKey, serverResult.keys.inboundMACKey)
            XCTAssertEqual(clientResult.keys.inboundMACKey, serverResult.keys.outboundMACKey)
            // The six keys are distinct.
            XCTAssertNotEqual(clientResult.keys.outboundMACKey, clientResult.keys.inboundMACKey)
        }

        try run(Curve25519.KeyAgreement.PrivateKey.self)
        try run(P256.KeyAgreement.PrivateKey.self)
        try run(P384.KeyAgreement.PrivateKey.self)
        try run(P521.KeyAgreement.PrivateKey.self)
    }

    /// End to end: a connection whose only transport protection needs long keys comes up, survives a rekey, and
    /// can open channels (every packet after NEWKEYS is MAC-checked with the derived keys).
    func testHandshakeWithLongKeyTransportProtection() throws {
        KeyCheckingTransportProtection.instances = []
        let channel = BackToBackEmbeddedChannel()
        defer { try? channel.finish() }

        let clientHandler = NIOSSHHandler(
            role: .client(
                .init(
                    userAuthDelegate: InfinitePasswordDelegate(),
                    serverAuthDelegate: AcceptAllHostKeysDelegate(),
                    transportProtectionSchemes: [KeyCheckingTransportProtection.self]
                )
            ),
            allocator: channel.client.allocator,
            inboundChildChannelInitializer: nil
        )
        let serverHandler = NIOSSHHandler(
            role: .server(
                .init(
                    hostKeys: [.init(ed25519Key: .init())],
                    userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 0),
                    transportProtectionSchemes: [KeyCheckingTransportProtection.self]
                )
            ),
            allocator: channel.server.allocator
        ) { channel, _ in
            channel.eventLoop.makeSucceededVoidFuture()
        }
        XCTAssertNoThrow(try channel.client.pipeline.syncOperations.addHandler(clientHandler))
        XCTAssertNoThrow(try channel.server.pipeline.syncOperations.addHandler(serverHandler))
        XCTAssertNoThrow(try channel.activate())
        XCTAssertNoThrow(try channel.interactInMemory())

        func openChannel() throws -> Bool {
            let promise = channel.client.eventLoop.makePromise(of: Channel.self)
            clientHandler.createChannel(promise) { channel, _ in channel.eventLoop.makeSucceededVoidFuture() }
            try channel.interactInMemory()
            return (try? promise.futureResult.wait())?.isActive ?? false
        }

        XCTAssertTrue(try openChannel())
        XCTAssertNoThrow(try clientHandler._rekey())
        XCTAssertNoThrow(try channel.interactInMemory())
        XCTAssertTrue(try openChannel())
        XCTAssertEqual(KeyCheckingTransportProtection.instances.count, 4)
    }
}
