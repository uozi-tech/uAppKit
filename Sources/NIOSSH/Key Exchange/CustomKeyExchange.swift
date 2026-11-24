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

// An extension point for key exchange methods that NIOSSH does not implement itself, such as finite-field
// Diffie-Hellman (`diffie-hellman-group14-sha256`, RFC 4253 §8 / RFC 8268).
//
// The implementation only does the arithmetic: produce an ephemeral public value and turn the peer's value into
// the shared secret K. NIOSSH does everything around it, exactly as for its own ECDH methods: it carries the
// values in SSH_MSG_KEX_ECDH_INIT / _REPLY (message numbers 30 and 31, which SSH_MSG_KEXDH_INIT / _REPLY share),
// computes the exchange hash H with the implementation's hash function, signs H with the host key (server) or
// verifies the host key's signature over it (client), and derives the session keys (RFC 4253 §7.2).

/// How a key exchange method encodes its ephemeral public values (`e` / `f`, or `Q_C` / `Q_S`) on the wire and
/// in the exchange hash.
public enum NIOSSHKeyExchangePublicValueEncoding: Sendable, Hashable {
    /// An opaque octet string, as in ECDH (RFC 5656) and Curve25519 (RFC 8731).
    case string

    /// A positive multiple-precision integer (`mpint`, RFC 4251 §5), as in finite-field Diffie-Hellman
    /// (RFC 4253 §8). Values are exchanged with the implementation as unsigned big-endian magnitudes; NIOSSH adds
    /// and strips the mpint encoding, and rejects negative values from the peer.
    case mpint
}

/// A key exchange method implemented outside NIOSSH.
///
/// NIOSSH creates one instance per key exchange (the initial one and every rekey), uses it on one event loop and
/// throws it away afterwards.
public protocol NIOSSHKeyExchangeAlgorithmProtocol: _NIOSSHSendableMetatype {
    /// The hash function of the method: used for the exchange hash H and for key derivation.
    associatedtype Hasher: HashFunction

    /// The names of the method as negotiated in KEXINIT (e.g. `diffie-hellman-group14-sha256`).
    static var keyExchangeAlgorithmNames: [Substring] { get }

    /// How the ephemeral public values are encoded. Defaults to `.string`.
    static var publicValueEncoding: NIOSSHKeyExchangePublicValueEncoding { get }

    /// Generates a fresh ephemeral key pair.
    init()

    /// Our ephemeral public value: `e` on the client, `f` on the server. With `.mpint` encoding, an unsigned
    /// big-endian magnitude (leading zero bytes are allowed); with `.string`, the exact octets.
    ///
    /// Read more than once per exchange: compute it in `init()` and store it.
    var publicValue: [UInt8] { get }

    /// Computes the shared secret K from the peer's ephemeral public value (same encoding rules as
    /// `publicValue`), as an unsigned big-endian magnitude. NIOSSH encodes it as an mpint.
    ///
    /// Called once per exchange. Validate the peer's value here (for Diffie-Hellman: `1 < f < p - 1`) and throw if
    /// it is unacceptable; that aborts the key exchange. As a backstop NIOSSH rejects an empty peer value, with
    /// `.mpint` encoding also 0 and 1, and a shared secret of 0 or 1; it cannot check the upper bound.
    mutating func sharedSecret(peerPublicValue: [UInt8]) throws -> [UInt8]
}

extension NIOSSHKeyExchangeAlgorithmProtocol {
    public static var publicValueEncoding: NIOSSHKeyExchangePublicValueEncoding { .string }
}

extension NIOSSHAlgorithms {
    /// Makes a key exchange method available under its `keyExchangeAlgorithmNames`.
    ///
    /// Registration does not enable the method: add its name to `keyExchangeAlgorithms` of the client or server
    /// configuration, at the position that expresses your preference. Registering the same type again does
    /// nothing.
    ///
    /// - Precondition: None of the names is a built-in method or registered by a different type.
    public static func register<KeyExchange: NIOSSHKeyExchangeAlgorithmProtocol>(
        keyExchangeAlgorithm: KeyExchange.Type
    ) {
        for name in KeyExchange.keyExchangeAlgorithmNames {
            precondition(
                !SSHKeyExchangeStateMachine.supportedKeyExchangeAlgorithms.contains(name)
                    && !SSHKeyExchangeStateMachine.keyExchangeExtensionMarkerNames.contains(name),
                "\(name) is a built-in key exchange method"
            )
        }
        self.keyExchangeRegistry.withLockedValue { registry in
            if registry.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(keyExchangeAlgorithm) }) {
                return
            }
            for other in registry {
                precondition(
                    !other.keyExchangeAlgorithmNames.contains(where: KeyExchange.keyExchangeAlgorithmNames.contains),
                    "\(KeyExchange.keyExchangeAlgorithmNames) is already registered for another type"
                )
            }
            registry.append(keyExchangeAlgorithm)
        }
    }

    private static let keyExchangeRegistry = NIOLockedValueBox<[any NIOSSHKeyExchangeAlgorithmProtocol.Type]>([])

    internal static func keyExchangeType(named name: Substring) -> (any NIOSSHKeyExchangeAlgorithmProtocol.Type)? {
        self.keyExchangeRegistry.withLockedValue { registry in
            registry.first { $0.keyExchangeAlgorithmNames.contains(name) }
        }
    }

    /// Test support: forget every registered key exchange method.
    internal static func _unregisterAllKeyExchangeAlgorithms() {
        self.keyExchangeRegistry.withLockedValue { $0.removeAll() }
    }
}

extension SSHConnectionRole {
    /// The configured key exchange methods, in order of preference.
    internal var keyExchangeAlgorithms: [String] {
        switch self {
        case .client(let configuration):
            return configuration.keyExchangeAlgorithms
        case .server(let configuration):
            return configuration.keyExchangeAlgorithms
        }
    }
}

extension SSHKeyExchangeStateMachine {
    /// The default of `keyExchangeAlgorithms` in both configurations: the built-in methods in upstream order.
    static var defaultKeyExchangeAlgorithms: [String] {
        Self.supportedKeyExchangeAlgorithms.map { String($0) }
    }

    /// Creates the exchanger for a registered method, or returns `nil` if `algorithm` is not registered.
    static func customExchanger(
        for algorithm: Substring,
        role: SSHConnectionRole,
        previousSessionIdentifier: ByteBuffer?
    ) -> EllipticCurveKeyExchangeProtocol? {
        guard let type = NIOSSHAlgorithms.keyExchangeType(named: algorithm) else {
            return nil
        }
        func make<Algorithm: NIOSSHKeyExchangeAlgorithmProtocol>(
            _: Algorithm.Type
        ) -> EllipticCurveKeyExchangeProtocol {
            CustomKeyExchange<Algorithm>(ourRole: role, previousSessionIdentifier: previousSessionIdentifier)
        }
        return make(type)
    }
}

/// Runs a custom key exchange method inside NIOSSH's key exchange state machine.
struct CustomKeyExchange<Algorithm: NIOSSHKeyExchangeAlgorithmProtocol>: EllipticCurveKeyExchangeProtocol {
    private var algorithm: Algorithm
    private var ourRole: SSHConnectionRole
    private var previousSessionIdentifier: ByteBuffer?

    init(ourRole: SSHConnectionRole, previousSessionIdentifier: ByteBuffer?) {
        self.algorithm = Algorithm()
        self.ourRole = ourRole
        self.previousSessionIdentifier = previousSessionIdentifier
    }

    static var keyExchangeAlgorithmNames: [Substring] {
        Algorithm.keyExchangeAlgorithmNames
    }

    func initiateKeyExchangeClientSide(allocator: ByteBufferAllocator) -> SSHMessage.KeyExchangeECDHInitMessage {
        precondition(self.ourRole.isClient, "Only clients may initiate the client side key exchange!")
        return .init(publicKey: Self.wireValue(self.algorithm.publicValue, allocator: allocator))
    }

    mutating func completeKeyExchangeServerSide(
        clientKeyExchangeMessage message: SSHMessage.KeyExchangeECDHInitMessage,
        serverHostKey: NIOSSHPrivateKey,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> (KeyExchangeResult, SSHMessage.KeyExchangeECDHReplyMessage) {
        precondition(self.ourRole.isServer, "Only servers may receive a client key exchange packet!")

        let clientValue = try Self.peerValue(message.publicKey)
        let (result, exchangeHash) = try self.finalize(
            clientValue: clientValue,
            serverValue: self.algorithm.publicValue,
            peerValue: clientValue,
            serverHostKey: serverHostKey.publicKey,
            initialExchangeBytes: &initialExchangeBytes,
            allocator: allocator,
            expectedKeySizes: expectedKeySizes
        )
        let reply = SSHMessage.KeyExchangeECDHReplyMessage(
            hostKey: serverHostKey.publicKey,
            publicKey: Self.wireValue(self.algorithm.publicValue, allocator: allocator),
            signature: try serverHostKey.sign(digest: exchangeHash)
        )
        return (result, reply)
    }

    mutating func receiveServerKeyExchangePayload(
        serverKeyExchangeMessage message: SSHMessage.KeyExchangeECDHReplyMessage,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> KeyExchangeResult {
        precondition(self.ourRole.isClient, "Only clients may receive a server key exchange packet!")

        let serverValue = try Self.peerValue(message.publicKey)
        let (result, exchangeHash) = try self.finalize(
            clientValue: self.algorithm.publicValue,
            serverValue: serverValue,
            peerValue: serverValue,
            serverHostKey: message.hostKey,
            initialExchangeBytes: &initialExchangeBytes,
            allocator: allocator,
            expectedKeySizes: expectedKeySizes
        )
        guard message.hostKey.isValidSignature(message.signature, for: exchangeHash) else {
            throw NIOSSHError.invalidExchangeHashSignature
        }
        return result
    }

    /// H = HASH(V_C || V_S || I_C || I_S || K_S || e || f || K); `initialExchangeBytes` already holds the first
    /// four. Returns the derived keys and H.
    private mutating func finalize(
        clientValue: [UInt8],
        serverValue: [UInt8],
        peerValue: [UInt8],
        serverHostKey: NIOSSHPublicKey,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> (KeyExchangeResult, Algorithm.Hasher.Digest) {
        let secret = try self.algorithm.sharedSecret(peerPublicValue: peerValue)
        // K = 0 or K = 1 means the exchange produced nothing secret (a peer value of 0, 1 or p - 1 in
        // finite-field Diffie-Hellman). The implementation should have rejected the peer value; check anyway.
        let significant = secret.drop(while: { $0 == 0 })
        guard !significant.isEmpty, Array(significant) != [1] else {
            throw NIOSSHError.weakSharedSecret(exchangeAlgorithm: String(Algorithm.keyExchangeAlgorithmNames.first ?? ""))
        }
        var encodedSecret = allocator.buffer(capacity: secret.count + 5)
        encodedSecret.writePositiveMPInt(secret)

        initialExchangeBytes.writeCompositeSSHString { $0.writeSSHHostKey(serverHostKey) }
        Self.writeHashValue(clientValue, to: &initialExchangeBytes)
        Self.writeHashValue(serverValue, to: &initialExchangeBytes)

        var hasher = Algorithm.Hasher()
        hasher.update(data: initialExchangeBytes.readableBytesView)
        hasher.update(data: encodedSecret.readableBytesView)
        let exchangeHash = hasher.finalize()

        let sessionID: ByteBuffer
        if let previousSessionIdentifier = self.previousSessionIdentifier {
            sessionID = previousSessionIdentifier
        } else {
            var hashBytes = allocator.buffer(capacity: Algorithm.Hasher.Digest.byteCount)
            hashBytes.writeContiguousBytes(exchangeHash)
            sessionID = hashBytes
        }

        let keys = self.deriveKeys(
            encodedSecret: encodedSecret,
            exchangeHash: exchangeHash,
            sessionID: sessionID,
            expectedKeySizes: expectedKeySizes
        )
        return (KeyExchangeResult(sessionID: sessionID, keys: keys), exchangeHash)
    }

    /// RFC 4253 §7.2, including the extension for keys longer than the hash.
    private func deriveKeys(
        encodedSecret: ByteBuffer,
        exchangeHash: Algorithm.Hasher.Digest,
        sessionID: ByteBuffer,
        expectedKeySizes: ExpectedKeySizes
    ) -> NIOSSHSessionKeys {
        var base = Algorithm.Hasher()
        base.update(data: encodedSecret.readableBytesView)
        exchangeHash.withUnsafeBytes { base.update(bufferPointer: $0) }
        func derive(_ letter: Character, _ length: Int) -> [UInt8] {
            base.sshDerivedKey(discriminatorByte: letter.asciiValue!, sessionID: sessionID, length: length)
        }

        let ivClientToServer = derive("A", expectedKeySizes.ivSize)
        let ivServerToClient = derive("B", expectedKeySizes.ivSize)
        let encryptionClientToServer = SymmetricKey(data: derive("C", expectedKeySizes.encryptionKeySize))
        let encryptionServerToClient = SymmetricKey(data: derive("D", expectedKeySizes.encryptionKeySize))
        let macClientToServer = SymmetricKey(data: derive("E", expectedKeySizes.macKeySize))
        let macServerToClient = SymmetricKey(data: derive("F", expectedKeySizes.macKeySize))

        if self.ourRole.isClient {
            return NIOSSHSessionKeys(
                initialInboundIV: ivServerToClient,
                initialOutboundIV: ivClientToServer,
                inboundEncryptionKey: encryptionServerToClient,
                outboundEncryptionKey: encryptionClientToServer,
                inboundMACKey: macServerToClient,
                outboundMACKey: macClientToServer
            )
        } else {
            return NIOSSHSessionKeys(
                initialInboundIV: ivClientToServer,
                initialOutboundIV: ivServerToClient,
                inboundEncryptionKey: encryptionClientToServer,
                outboundEncryptionKey: encryptionServerToClient,
                inboundMACKey: macClientToServer,
                outboundMACKey: macServerToClient
            )
        }
    }

    /// The contents of the SSH string that carries `value` in the init / reply message. An mpint is wire-identical
    /// to a string holding its two's-complement bytes.
    private static func wireValue(_ value: [UInt8], allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: value.count + 5)
        switch Algorithm.publicValueEncoding {
        case .string:
            buffer.writeBytes(value)
        case .mpint:
            buffer.writePositiveMPInt(value)
            buffer.moveReaderIndex(forwardBy: 4)  // Drop the length: the message writes the string's own.
        }
        return buffer
    }

    /// Undoes `wireValue` for the peer's value.
    private static func peerValue(_ wire: ByteBuffer) throws -> [UInt8] {
        let bytes = Array(wire.readableBytesView)
        guard !bytes.isEmpty else {
            throw NIOSSHError.invalidSSHMessage(reason: "empty public value in key exchange")
        }
        switch Algorithm.publicValueEncoding {
        case .string:
            return bytes
        case .mpint:
            guard (bytes.first ?? 0) & 0x80 == 0 else {
                throw NIOSSHError.invalidSSHMessage(reason: "negative mpint in key exchange")
            }
            let magnitude = Array(bytes.drop(while: { $0 == 0 }))
            // 0 and 1 are never valid Diffie-Hellman public values (RFC 4253 §8 requires 1 < f < p - 1; NIOSSH
            // does not know p, so the upper bound stays with the implementation).
            guard !magnitude.isEmpty, magnitude != [1] else {
                throw NIOSSHError.invalidSSHMessage(reason: "degenerate public value in key exchange")
            }
            return magnitude
        }
    }

    /// Writes a public value into the exchange hash input: as a string, or as a canonical mpint (what OpenSSH
    /// hashes, whatever leading zeros the peer sent).
    private static func writeHashValue(_ value: [UInt8], to buffer: inout ByteBuffer) {
        switch Algorithm.publicValueEncoding {
        case .string:
            buffer.writeSSHString(value)
        case .mpint:
            buffer.writePositiveMPInt(value)
        }
    }
}
