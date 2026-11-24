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

// A toy custom public key algorithm, shaped like RSA in SSH: one key format (`toy-key@…`, think `ssh-rsa`) used
// with two algorithms (`toy-sig@…` / `toy-sig-alt@…`, think `rsa-sha2-512` / `rsa-sha2-256`) whose names differ
// from the key format. Ed25519 does the actual signing; the "alt" algorithm signs a domain-separated message so
// that its signatures are distinct.

enum ToyKeyError: Error {
    case malformed
    case unsupported
}

struct ToyPublicKey: NIOSSHPublicKeyProtocol {
    static let publicKeyPrefix = "toy-key@test.uappkit"

    let key: Curve25519.Signing.PublicKey

    var rawRepresentation: Data { self.key.rawRepresentation }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        switch signature {
        case let signature as ToySignature:
            return self.key.isValidSignature(signature.rawRepresentation, for: Data(data))
        case let signature as ToyAltSignature:
            return self.key.isValidSignature(signature.rawRepresentation, for: ToyAltSignature.domain + Data(data))
        default:
            return false
        }
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(self.key.rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> ToyPublicKey {
        guard let bytes = buffer.readSSHString() else {
            throw ToyKeyError.malformed
        }
        return ToyPublicKey(key: try .init(rawRepresentation: bytes.readableBytesView))
    }
}

struct ToySignature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "toy-sig@test.uappkit"

    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(self.rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> ToySignature {
        guard let bytes = buffer.readSSHString() else {
            throw ToyKeyError.malformed
        }
        return ToySignature(rawRepresentation: Data(bytes.readableBytesView))
    }
}

struct ToyAltSignature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "toy-sig-alt@test.uappkit"
    static let domain = Data("alt".utf8)

    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(self.rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> ToyAltSignature {
        guard let bytes = buffer.readSSHString() else {
            throw ToyKeyError.malformed
        }
        return ToyAltSignature(rawRepresentation: Data(bytes.readableBytesView))
    }
}

/// Signs with `toy-sig@…`.
struct ToyPrivateKey: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = ToySignature.signaturePrefix

    let key: Curve25519.Signing.PrivateKey

    var publicKey: NIOSSHPublicKeyProtocol { ToyPublicKey(key: self.key.publicKey) }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        ToySignature(rawRepresentation: try self.key.signature(for: Data(data)))
    }
}

/// The same key, signing with `toy-sig-alt@…`.
struct ToyAltPrivateKey: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = ToyAltSignature.signaturePrefix

    let key: Curve25519.Signing.PrivateKey

    var publicKey: NIOSSHPublicKeyProtocol { ToyPublicKey(key: self.key.publicKey) }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        ToyAltSignature(rawRepresentation: try self.key.signature(for: ToyAltSignature.domain + Data(data)))
    }
}

/// A misbehaving key: claims `toy-sig@…` but produces `toy-sig-alt@…` signatures (valid ones, for the same key).
/// Models a server that negotiates `rsa-sha2-512` and then answers with an `ssh-rsa` SHA-1 signature.
struct MismatchedToyPrivateKey: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = ToySignature.signaturePrefix

    let key: Curve25519.Signing.PrivateKey

    var publicKey: NIOSSHPublicKeyProtocol { ToyPublicKey(key: self.key.publicKey) }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        try ToyAltPrivateKey(key: self.key).signature(for: data)
    }
}

/// Registers the toy algorithms in `setUp` and removes them again in `tearDown`, so that the rest of the suite
/// sees an empty registry.
class CustomAlgorithmTestCase: XCTestCase {
    var registersToyKeys: Bool { true }

    override func setUp() {
        super.setUp()
        NIOSSHAlgorithms._unregisterAllPublicKeyAlgorithms()
        if self.registersToyKeys {
            NIOSSHAlgorithms.register(publicKey: ToyPublicKey.self, signature: ToySignature.self)
            NIOSSHAlgorithms.register(publicKey: ToyPublicKey.self, signature: ToyAltSignature.self)
        }
    }

    override func tearDown() {
        NIOSSHAlgorithms._unregisterAllPublicKeyAlgorithms()
        super.tearDown()
    }
}

/// Counts `UserAuthSuccessEvent`s on the client.
final class UserAuthSuccessRecorder: ChannelInboundHandler {
    typealias InboundIn = Any

    private(set) var successes = 0

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            self.successes += 1
        }
        context.fireUserInboundEventTriggered(event)
    }
}

/// A server delegate that accepts one public key and records how often it was asked.
final class RecordingPublicKeyAuth: NIOSSHServerUserAuthenticationDelegate {
    private let key: NIOSSHPublicKey
    private(set) var requests = 0

    init(_ key: NIOSSHPublicKey) {
        self.key = key
    }

    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        self.requests += 1
        guard case .publicKey(let offered) = request.request, offered.publicKey == self.key else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

final class RecordingHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private(set) var hostKeys: [NIOSSHPublicKey] = []

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        self.hostKeys.append(hostKey)
        validationCompletePromise.succeed(())
    }
}

final class CustomKeyTests: CustomAlgorithmTestCase {
    private let ed25519 = Curve25519.Signing.PrivateKey()

    // MARK: Keys and signatures

    func testCustomPublicKeyRoundTripsThroughTheWireFormat() throws {
        let key = NIOSSHPublicKey(custom: ToyPublicKey(key: self.ed25519.publicKey))

        var buffer = ByteBuffer()
        let written = key.write(to: &buffer)
        XCTAssertEqual(written, buffer.readableBytes)
        XCTAssertEqual(buffer.getSSHString(at: buffer.readerIndex).map { String(buffer: $0) }, ToyPublicKey.publicKeyPrefix)

        let parsed = try buffer.readSSHHostKey()
        XCTAssertEqual(parsed, key)
        XCTAssertEqual(parsed?.hashValue, key.hashValue)
        XCTAssertEqual(buffer.readableBytes, 0)
        XCTAssertTrue(parsed?.keyPrefix.elementsEqual(ToyPublicKey.publicKeyPrefix.utf8) ?? false)

        let openSSH = String(openSSHPublicKey: key)
        XCTAssertTrue(openSSH.hasPrefix(ToyPublicKey.publicKeyPrefix + " "))
        XCTAssertEqual(try NIOSSHPublicKey(openSSHPublicKey: openSSH), key)

        // Different key material, different key.
        XCTAssertNotEqual(key, NIOSSHPublicKey(custom: ToyPublicKey(key: Curve25519.Signing.PrivateKey().publicKey)))
        // Same bytes, but a built-in key is never equal to a custom one.
        XCTAssertNotEqual(key, NIOSSHPrivateKey(ed25519Key: self.ed25519).publicKey)
    }

    func testCustomPrivateKeyExposesItsPublicKeyAndAlgorithm() throws {
        let privateKey = NIOSSHPrivateKey(custom: ToyAltPrivateKey(key: self.ed25519))
        XCTAssertEqual(privateKey.publicKey, NIOSSHPublicKey(custom: ToyPublicKey(key: self.ed25519.publicKey)))
        XCTAssertEqual(privateKey.hostKeyAlgorithms, [Substring(ToyAltSignature.signaturePrefix)])
        XCTAssertEqual(privateKey.customAlgorithmName, ToyAltSignature.signaturePrefix)
        XCTAssertNil(NIOSSHPrivateKey(ed25519Key: self.ed25519).customAlgorithmName)
    }

    func testCustomSignaturesRoundTripAndVerify() throws {
        let privateKey = NIOSSHPrivateKey(custom: ToyPrivateKey(key: self.ed25519))
        let altPrivateKey = NIOSSHPrivateKey(custom: ToyAltPrivateKey(key: self.ed25519))
        let digest = SHA256.hash(data: Data("exchange hash".utf8))

        let signature = try privateKey.sign(digest: digest)
        let altSignature = try altPrivateKey.sign(digest: digest)
        XCTAssertNotEqual(signature, altSignature)

        for sig in [signature, altSignature] {
            var buffer = ByteBuffer()
            buffer.writeSSHSignature(sig)
            let parsed = try buffer.readSSHSignature()
            XCTAssertEqual(parsed, sig)
            XCTAssertEqual(parsed?.hashValue, sig.hashValue)
            XCTAssertTrue(privateKey.publicKey.isValidSignature(parsed!, for: digest))
        }

        let otherDigest = SHA256.hash(data: Data("something else".utf8))
        XCTAssertFalse(privateKey.publicKey.isValidSignature(signature, for: otherDigest))
        // A custom key never accepts a built-in signature, and vice versa.
        let builtIn = try NIOSSHPrivateKey(ed25519Key: self.ed25519).sign(digest: digest)
        XCTAssertFalse(privateKey.publicKey.isValidSignature(builtIn, for: digest))
        XCTAssertFalse(NIOSSHPrivateKey(ed25519Key: self.ed25519).publicKey.isValidSignature(signature, for: digest))
    }

    func testAlgorithmNamesAreSeparateFromTheKeyType() throws {
        let key = NIOSSHPublicKey(custom: ToyPublicKey(key: self.ed25519.publicKey))
        let digest = SHA256.hash(data: Data("h".utf8))
        let signature = try NIOSSHPrivateKey(custom: ToyPrivateKey(key: self.ed25519)).sign(digest: digest)
        let altSignature = try NIOSSHPrivateKey(custom: ToyAltPrivateKey(key: self.ed25519)).sign(digest: digest)

        XCTAssertTrue(key.isUsable(withAlgorithm: ToySignature.signaturePrefix.utf8, signature: nil))
        XCTAssertTrue(key.isUsable(withAlgorithm: ToyAltSignature.signaturePrefix.utf8, signature: nil))
        XCTAssertTrue(key.isUsable(withAlgorithm: ToySignature.signaturePrefix.utf8, signature: signature))
        XCTAssertFalse(key.isUsable(withAlgorithm: ToySignature.signaturePrefix.utf8, signature: altSignature))
        // The key type itself is not an algorithm unless something registers it as one.
        XCTAssertFalse(key.isUsable(withAlgorithm: ToyPublicKey.publicKeyPrefix.utf8, signature: nil))
        XCTAssertFalse(key.isUsable(withAlgorithm: "ssh-ed25519".utf8, signature: nil))
        // Built-in keys are unchanged: their algorithm is their prefix.
        let builtIn = NIOSSHPrivateKey(ed25519Key: self.ed25519).publicKey
        XCTAssertTrue(builtIn.isUsable(withAlgorithm: "ssh-ed25519".utf8, signature: nil))
        XCTAssertFalse(builtIn.isUsable(withAlgorithm: ToySignature.signaturePrefix.utf8, signature: nil))
    }

    func testRegistrationIsIdempotentAndOrdered() {
        NIOSSHAlgorithms.register(publicKey: ToyPublicKey.self, signature: ToySignature.self)
        NIOSSHAlgorithms.register(publicKey: ToyPublicKey.self, signature: ToyAltSignature.self)
        XCTAssertEqual(
            NIOSSHAlgorithms.registeredPublicKeyAlgorithms,
            [ToySignature.signaturePrefix, ToyAltSignature.signaturePrefix]
        )
        XCTAssertEqual(
            NIOSSHPublicKey.knownAlgorithms.map { String($0) },
            ["ssh-ed25519", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp521"]
                + [ToySignature.signaturePrefix, ToyAltSignature.signaturePrefix]
        )
    }

    func testClientOffersRegisteredHostKeyAlgorithmsAfterTheBuiltInOnes() {
        let client = SSHKeyExchangeStateMachine(
            allocator: ByteBufferAllocator(),
            loop: EmbeddedEventLoop(),
            role: .client(
                .init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())
            ),
            remoteVersion: Constants.version,
            protectionSchemes: [AES256GCMOpenSSHTransportProtection.self],
            previousSessionIdentifier: nil
        )
        XCTAssertEqual(
            client.createKeyExchangeMessage().serverHostKeyAlgorithms,
            SSHKeyExchangeStateMachine.supportedServerHostKeyAlgorithms
                + [Substring(ToySignature.signaturePrefix), Substring(ToyAltSignature.signaturePrefix)]
        )
    }

    // MARK: User authentication messages

    func testUserAuthRequestCarriesTheAlgorithmNameNotTheKeyType() throws {
        var sessionID = ByteBuffer()
        sessionID.writeBytes(0..<32)
        let offer = NIOSSHUserAuthenticationOffer(
            username: "foo",
            serviceName: "",
            offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(custom: ToyAltPrivateKey(key: self.ed25519))))
        )
        let message = try SSHMessage.UserAuthRequestMessage(request: offer, sessionID: sessionID)
        XCTAssertEqual(message.publicKeyAlgorithm, ToyAltSignature.signaturePrefix)

        var buffer = ByteBuffer()
        _ = buffer.writeUserAuthRequestMessage(message)

        // username, service, "publickey", TRUE, algorithm name, key blob (whose type is the key format).
        var reader = buffer
        XCTAssertEqual(reader.readSSHStringAsString(), "foo")
        XCTAssertEqual(reader.readSSHStringAsString(), "ssh-connection")
        XCTAssertEqual(reader.readSSHStringAsString(), "publickey")
        XCTAssertEqual(reader.readSSHBoolean(), true)
        XCTAssertEqual(reader.readSSHStringAsString(), ToyAltSignature.signaturePrefix)
        var blob = reader.readSSHString()!
        XCTAssertEqual(blob.readSSHStringAsString(), ToyPublicKey.publicKeyPrefix)

        let parsed = try buffer.readUserAuthRequestMessage()
        XCTAssertEqual(parsed, message)
        guard case .publicKey(.known(key: let key, signature: .some(let signature))) = parsed?.method else {
            XCTFail("Unexpected method: \(String(describing: parsed?.method))")
            return
        }
        let payload = UserAuthSignablePayload(
            sessionIdentifier: sessionID,
            userName: "foo",
            serviceName: "ssh-connection",
            publicKey: key,
            publicKeyAlgorithm: parsed?.publicKeyAlgorithm
        )
        XCTAssertTrue(key.isValidSignature(signature, for: payload))
    }

    func testUserAuthRequestWithMismatchedSignatureAlgorithmIsRejected() throws {
        var sessionID = ByteBuffer()
        sessionID.writeBytes(0..<32)
        let offer = NIOSSHUserAuthenticationOffer(
            username: "foo",
            serviceName: "",
            offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(custom: MismatchedToyPrivateKey(key: self.ed25519))))
        )
        let message = try SSHMessage.UserAuthRequestMessage(request: offer, sessionID: sessionID)
        var buffer = ByteBuffer()
        _ = buffer.writeUserAuthRequestMessage(message)
        XCTAssertThrowsError(try buffer.readUserAuthRequestMessage()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .invalidSSHMessage)
        }
    }

    func testPublicKeyOKEchoesTheAlgorithmName() throws {
        let key = NIOSSHPublicKey(custom: ToyPublicKey(key: self.ed25519.publicKey))
        let message = SSHMessage.UserAuthPKOKMessage(key: key, publicKeyAlgorithm: ToyAltSignature.signaturePrefix)
        var buffer = ByteBuffer()
        _ = buffer.writeUserAuthPKOKMessage(message)
        XCTAssertEqual(buffer.getSSHString(at: buffer.readerIndex).map { String(buffer: $0) }, ToyAltSignature.signaturePrefix)
        XCTAssertEqual(try buffer.readUserAuthPKOKMessage(), message)
    }

    // MARK: End to end

    private var channel: BackToBackEmbeddedChannel!

    override func setUp() {
        super.setUp()
        self.channel = BackToBackEmbeddedChannel()
    }

    override func tearDown() {
        try? self.channel.finish()
        self.channel = nil
        super.tearDown()
    }

    func testCustomUserKeyAuthenticates() throws {
        let userKey = NIOSSHPrivateKey(custom: ToyPrivateKey(key: self.ed25519))
        let serverAuth = RecordingPublicKeyAuth(userKey.publicKey)
        let successes = UserAuthSuccessRecorder()
        var harness = TestHarness()
        harness.clientAuthDelegate = PrivateKeyClientAuth(userKey)
        harness.serverAuthDelegate = serverAuth

        XCTAssertNoThrow(try self.channel.configureWithHarness(harness))
        XCTAssertNoThrow(try self.channel.client.pipeline.syncOperations.addHandler(successes))
        XCTAssertNoThrow(try self.channel.activate())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(serverAuth.requests, 1)
        XCTAssertEqual(successes.successes, 1)

        // Authenticated: channels can be opened.
        self.channel.clientSSHHandler?.createChannel(nil, nil)
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(self.channel.activeServerChannels.count, 1)
    }

    func testCustomHostKeyWithAnAlgorithmOtherThanItsKeyType() throws {
        // The server offers the same key under both algorithms; the client prefers the one registered first.
        let hostKeys = [
            NIOSSHPrivateKey(custom: ToyAltPrivateKey(key: self.ed25519)),
            NIOSSHPrivateKey(custom: ToyPrivateKey(key: self.ed25519)),
        ]
        let recorder = RecordingHostKeyDelegate()
        var harness = TestHarness()
        harness.serverHostKeys = hostKeys
        harness.clientServerAuthDelegate = recorder

        XCTAssertNoThrow(try self.channel.configureWithHarness(harness))
        XCTAssertNoThrow(try self.channel.activate())
        XCTAssertNoThrow(try self.channel.interactInMemory())

        XCTAssertEqual(recorder.hostKeys, [NIOSSHPublicKey(custom: ToyPublicKey(key: self.ed25519.publicKey))])
        self.channel.clientSSHHandler?.createChannel(nil, nil)
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(self.channel.activeServerChannels.count, 1)

        // And it survives a rekey.
        XCTAssertNoThrow(try self.channel.clientSSHHandler!._rekey())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        self.channel.clientSSHHandler?.createChannel(nil, nil)
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(self.channel.activeServerChannels.count, 2)
        XCTAssertEqual(recorder.hostKeys.count, 2)
    }

    func testHostSignatureOfADifferentAlgorithmIsRejected() throws {
        var harness = TestHarness()
        harness.serverHostKeys = [NIOSSHPrivateKey(custom: MismatchedToyPrivateKey(key: self.ed25519))]

        XCTAssertNoThrow(try self.channel.configureWithHarness(harness))
        XCTAssertNoThrow(try self.channel.activate())
        XCTAssertThrowsError(try self.channel.interactInMemory()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .invalidHostKeyForKeyExchange)
        }
    }
}

/// The same scenarios with nothing registered: everything fails cleanly instead of trapping.
final class UnregisteredCustomKeyTests: CustomAlgorithmTestCase {
    override var registersToyKeys: Bool { false }

    private var channel: BackToBackEmbeddedChannel!
    private let ed25519 = Curve25519.Signing.PrivateKey()

    override func setUp() {
        super.setUp()
        self.channel = BackToBackEmbeddedChannel()
    }

    override func tearDown() {
        try? self.channel.finish()
        self.channel = nil
        super.tearDown()
    }

    func testUnregisteredKeyTypesAndSignaturesDoNotParse() throws {
        var buffer = ByteBuffer()
        NIOSSHPublicKey(custom: ToyPublicKey(key: self.ed25519.publicKey)).write(to: &buffer)
        XCTAssertThrowsError(try buffer.readSSHHostKey()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .unknownPublicKey)
        }

        let signature = try NIOSSHPrivateKey(custom: ToyPrivateKey(key: self.ed25519))
            .sign(digest: SHA256.hash(data: Data()))
        buffer.clear()
        buffer.writeSSHSignature(signature)
        XCTAssertThrowsError(try buffer.readSSHSignature()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .unknownSignature)
        }
        XCTAssertEqual(NIOSSHAlgorithms.registeredPublicKeyAlgorithms, [])
    }

    func testUnregisteredHostKeyAlgorithmFailsNegotiation() throws {
        var harness = TestHarness()
        harness.serverHostKeys = [NIOSSHPrivateKey(custom: ToyPrivateKey(key: self.ed25519))]

        XCTAssertNoThrow(try self.channel.configureWithHarness(harness))
        XCTAssertNoThrow(try self.channel.activate())
        XCTAssertThrowsError(try self.channel.interactInMemory()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .keyExchangeNegotiationFailure)
        }
    }

    func testUnregisteredUserKeyIsRefused() throws {
        let userKey = NIOSSHPrivateKey(custom: ToyPrivateKey(key: self.ed25519))
        let serverAuth = RecordingPublicKeyAuth(userKey.publicKey)
        let successes = UserAuthSuccessRecorder()
        var harness = TestHarness()
        harness.clientAuthDelegate = PrivateKeyClientAuth(userKey)
        harness.serverAuthDelegate = serverAuth

        XCTAssertNoThrow(try self.channel.configureWithHarness(harness))
        XCTAssertNoThrow(try self.channel.client.pipeline.syncOperations.addHandler(successes))
        XCTAssertNoThrow(try self.channel.activate())
        // The server does not know the algorithm: it answers with a failure without consulting its delegate, the
        // client has nothing else to offer, and the connection never authenticates. Nothing traps.
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(serverAuth.requests, 0)
        XCTAssertEqual(successes.successes, 0)
    }
}
