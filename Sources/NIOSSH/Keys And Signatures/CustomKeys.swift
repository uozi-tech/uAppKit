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

import NIOConcurrencyHelpers
import NIOCore

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// An extension point for public key algorithms that NIOSSH does not implement itself (RSA, for instance).
//
// SSH separates two names that coincide for every algorithm NIOSSH ships:
//
// - the *key format identifier* at the start of a public key blob (RFC 4253 §6.6), e.g. `ssh-rsa`;
// - the *public key algorithm name* used in SSH_MSG_USERAUTH_REQUEST, in `server_host_key_algorithms` and as
//   the format identifier of a signature (RFC 4252 §7, RFC 8332), e.g. `rsa-sha2-512`.
//
// Here the first is `NIOSSHPublicKeyProtocol.publicKeyPrefix`, the second is
// `NIOSSHSignatureProtocol.signaturePrefix`, and `NIOSSHAlgorithms.register(publicKey:signature:)` declares that
// a key format can be used with an algorithm. One key format may be registered with several algorithms (one
// signature type each), which is how `ssh-rsa` keys get `rsa-sha2-512`, `rsa-sha2-256` and `ssh-rsa`.

/// A signature produced by a custom public key algorithm.
public protocol NIOSSHSignatureProtocol: Sendable {
    /// The signature format identifier, which in SSH is the public key algorithm name (e.g. `rsa-sha2-512`).
    ///
    /// It must be unique across all registered signature types and must not be one of NIOSSH's built-in names.
    static var signaturePrefix: String { get }

    /// A canonical byte representation of the signature, used for equality and hashing.
    var rawRepresentation: Data { get }

    /// Writes the signature blob that follows the format identifier (NIOSSH writes the identifier itself) and
    /// returns the number of bytes written. For SSH's usual `string signature` blob, that is a length-prefixed
    /// string.
    func write(to buffer: inout ByteBuffer) -> Int

    /// Reads what `write(to:)` wrote. `buffer` holds the rest of the signature blob, after the identifier.
    static func read(from buffer: inout ByteBuffer) throws -> Self
}

/// A public key of a custom key format.
public protocol NIOSSHPublicKeyProtocol: Sendable {
    /// The key format identifier at the start of the public key blob (e.g. `ssh-rsa`).
    ///
    /// It must be unique across all registered public key types and must not be one of NIOSSH's built-in names.
    static var publicKeyPrefix: String { get }

    /// A canonical byte representation of the key, used for equality and hashing.
    var rawRepresentation: Data { get }

    /// Whether `signature` is a valid signature over `data` made by the matching private key.
    ///
    /// `signature` may be of any registered signature type; implementations check its type (and therefore its
    /// algorithm) themselves. For a host key, `data` is the exchange hash H; for user authentication it is the
    /// RFC 4252 §7 signed data.
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool

    /// Writes the public key blob that follows the format identifier (NIOSSH writes the identifier itself) and
    /// returns the number of bytes written. For `ssh-rsa` that is `mpint e, mpint n`.
    ///
    /// The output must be byte-for-byte what `read(from:)` consumed: the exchange hash includes the server's host
    /// key blob, and NIOSSH re-serializes the parsed key to compute it. Keep the received bytes if the encoding
    /// is not canonical.
    func write(to buffer: inout ByteBuffer) -> Int

    /// Reads what `write(to:)` wrote. `buffer` holds the rest of the key blob, after the identifier.
    static func read(from buffer: inout ByteBuffer) throws -> Self
}

/// A private key of a custom key format.
public protocol NIOSSHPrivateKeyProtocol: Sendable {
    /// The public key algorithm name this key signs with (e.g. `rsa-sha2-512`).
    ///
    /// It is sent as the algorithm name in user authentication and offered as a host key algorithm. Signatures
    /// returned by `signature(for:)` must have this `signaturePrefix`, and the algorithm must be registered for
    /// the key format of `publicKey`. To offer one key under several algorithms, wrap it in several private key
    /// types (as host keys: pass all of them in `SSHServerConfiguration.hostKeys`).
    static var keyPrefix: String { get }

    /// The matching public key.
    var publicKey: NIOSSHPublicKeyProtocol { get }

    /// Signs `data`: the exchange hash H when used as a host key, the RFC 4252 §7 signed data in user
    /// authentication.
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol
}

/// The registry of custom algorithms.
///
/// Registration is process-wide and thread-safe. Register everything before the connections that should use it
/// start: a connection reads the registry while it negotiates.
public enum NIOSSHAlgorithms {
    /// Makes the public key algorithm `Signature.signaturePrefix` available for keys of format
    /// `PublicKey.publicKeyPrefix`.
    ///
    /// Afterwards NIOSSH parses such keys and signatures, accepts them in user authentication, and clients offer
    /// the algorithm in `server_host_key_algorithms` (after the built-in algorithms, in registration order).
    /// Registering the same pair again does nothing.
    ///
    /// - Precondition: Neither name is a built-in one, and neither name is already taken by a different type.
    public static func register<PublicKey: NIOSSHPublicKeyProtocol, Signature: NIOSSHSignatureProtocol>(
        publicKey: PublicKey.Type,
        signature: Signature.Type
    ) {
        let keyName = PublicKey.publicKeyPrefix
        let algorithm = Signature.signaturePrefix
        precondition(
            !NIOSSHPublicKey.builtInKeyAlgorithms.contains { $0.elementsEqual(keyName.utf8) },
            "\(keyName) is a built-in key type"
        )
        precondition(
            !NIOSSHPublicKey.builtInKeyAlgorithms.contains { $0.elementsEqual(algorithm.utf8) },
            "\(algorithm) is a built-in algorithm"
        )
        self.registry.withLockedValue { registry in
            if let other = registry.first(where: { $0.publicKey.publicKeyPrefix == keyName }) {
                precondition(ObjectIdentifier(other.publicKey) == ObjectIdentifier(publicKey), "\(keyName) is already registered for another type")
            }
            if let other = registry.first(where: { $0.signature.signaturePrefix == algorithm }) {
                precondition(ObjectIdentifier(other.signature) == ObjectIdentifier(signature), "\(algorithm) is already registered for another type")
            }
            if !registry.contains(where: {
                ObjectIdentifier($0.publicKey) == ObjectIdentifier(publicKey)
                    && ObjectIdentifier($0.signature) == ObjectIdentifier(signature)
            }) {
                registry.append((publicKey, signature))
            }
        }
    }

    private static let registry = NIOLockedValueBox<
        [(publicKey: any NIOSSHPublicKeyProtocol.Type, signature: any NIOSSHSignatureProtocol.Type)]
    >([])

    /// Registered public key algorithm names, in registration order, without duplicates.
    internal static var registeredPublicKeyAlgorithms: [String] {
        self.registry.withLockedValue { registry in
            var names: [String] = []
            for entry in registry where !names.contains(entry.signature.signaturePrefix) {
                names.append(entry.signature.signaturePrefix)
            }
            return names
        }
    }

    internal static func publicKeyType<Bytes: Collection>(
        forPrefix prefix: Bytes
    ) -> (any NIOSSHPublicKeyProtocol.Type)? where Bytes.Element == UInt8 {
        self.registry.withLockedValue { registry in
            registry.first { $0.publicKey.publicKeyPrefix.utf8.elementsEqual(prefix) }?.publicKey
        }
    }

    internal static func signatureType<Bytes: Collection>(
        forPrefix prefix: Bytes
    ) -> (any NIOSSHSignatureProtocol.Type)? where Bytes.Element == UInt8 {
        self.registry.withLockedValue { registry in
            registry.first { $0.signature.signaturePrefix.utf8.elementsEqual(prefix) }?.signature
        }
    }

    /// Whether `algorithm` is registered for keys of type `publicKey`.
    internal static func isRegistered<Bytes: Collection>(
        publicKey: any NIOSSHPublicKeyProtocol.Type,
        algorithm: Bytes
    ) -> Bool where Bytes.Element == UInt8 {
        self.registry.withLockedValue { registry in
            registry.contains {
                ObjectIdentifier($0.publicKey) == ObjectIdentifier(publicKey)
                    && $0.signature.signaturePrefix.utf8.elementsEqual(algorithm)
            }
        }
    }

    /// Test support: forget every registered public key algorithm.
    internal static func _unregisterAllPublicKeyAlgorithms() {
        self.registry.withLockedValue { $0.removeAll() }
    }
}

extension NIOSSHPublicKey {
    /// Wraps a custom public key. Its key format must be registered with `NIOSSHAlgorithms` for NIOSSH to parse it
    /// back or to accept it from a peer; writing it works regardless.
    public init<Key: NIOSSHPublicKeyProtocol>(custom key: Key) {
        self.backingKey = .custom(key)
    }

    /// Writes the public key blob (format identifier and key data), as used in SSH messages and OpenSSH files.
    @discardableResult
    public func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHHostKey(self)
    }

    /// Whether this key can be used with the public key algorithm `algorithm`, and, if `signature` is given,
    /// whether that signature belongs to the algorithm.
    ///
    /// Built-in keys have a single algorithm, their key prefix, and this is the upstream comparison. A custom key
    /// supports the algorithms registered for its type, and its signature must be of that very algorithm (an
    /// `ssh-rsa` key negotiated as `rsa-sha2-512` must not be answered with an `ssh-rsa` SHA-1 signature).
    internal func isUsable<Bytes: Collection>(
        withAlgorithm algorithm: Bytes,
        signature: NIOSSHSignature?
    ) -> Bool where Bytes.Element == UInt8 {
        guard case .custom(let key) = self.backingKey else {
            return self.keyPrefix.elementsEqual(algorithm)
        }
        guard NIOSSHAlgorithms.isRegistered(publicKey: type(of: key), algorithm: algorithm) else {
            return false
        }
        guard let signature = signature else {
            return true
        }
        guard case .custom(let customSignature) = signature.backingSignature else {
            return false
        }
        return type(of: customSignature).signaturePrefix.utf8.elementsEqual(algorithm)
    }

    /// The prefixes NIOSSH itself implements.
    internal static var builtInKeyAlgorithms: [String.UTF8View] {
        [
            Self.ed25519PublicKeyPrefix, Self.ecdsaP384PublicKeyPrefix, Self.ecdsaP256PublicKeyPrefix,
            Self.ecdsaP521PublicKeyPrefix,
        ]
    }
}

extension NIOSSHPrivateKey {
    /// Wraps a custom private key. Its algorithm (`Key.keyPrefix`) must be registered with `NIOSSHAlgorithms` for
    /// the format of its public key on the side that verifies its signatures.
    public init<Key: NIOSSHPrivateKeyProtocol>(custom key: Key) {
        self.backingKey = .custom(key)
    }

    /// The public key algorithm name a custom key signs with; `nil` for built-in keys, whose algorithm is their
    /// key prefix.
    internal var customAlgorithmName: String? {
        guard case .custom(let key) = self.backingKey else {
            return nil
        }
        return type(of: key).keyPrefix
    }
}
