//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
// Modified by uAppKit: see ThirdParty/swift-nio-ssh/PATCHES.md for the list of changes.
//
//===----------------------------------------------------------------------===//

import NIOCore

/// A ``NIOSSHClientUserAuthenticationDelegate`` is an object that can provide a sequence of
/// SSH user authentication methods based on the the acceptable list from the server.
///
/// This protocol defines the interface that will be used by the user authentication state
/// machine to move forward with challenges. Implementers of this protocol are free to take
/// time to actually get responses: for example, for password authentication it is possible
/// that the application would like to provide a user-interactive password prompt. This is
/// enabled by allowing implementers to satisfy a promise, rather than requiring that they
/// synchronously provide a response.
public protocol NIOSSHClientUserAuthenticationDelegate {
    /// Called when ``NIOSSH`` would like to attempt to offer a new authentication method.
    ///
    /// The callback is provided the authentication methods that the server is willing to accept in
    /// `availableMethods`. The delegate needs to provide an authentication offer by completing
    /// `nextChallengePromise`. If no further authentication offers are available (perhaps because the server
    /// has rejected them all) then this promise should be failed, which will terminate connection establishment.
    ///
    /// - parameters:
    ///     - availableMethods: The authentication methods the server is willing to accept.
    ///     - nextChallengePromise: An `EventLoopPromise` to be fulfilled with the next authentication offer.
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    )

    /// The same, plus the public key algorithms the server accepts for user authentication, as announced in the
    /// RFC 8308 `server-sig-algs` extension (`nil` if the server did not send it). This is the variant NIOSSH calls;
    /// the default implementation drops `serverSignatureAlgorithms` and calls the variant above.
    ///
    /// Implement it to pick, say, `rsa-sha2-512` / `rsa-sha2-256` / `ssh-rsa` for an RSA key without spending
    /// authentication attempts on algorithms the server refuses. The extension, when sent, arrives before the
    /// first call; a server may update it right before authentication succeeds, which no later call observes.
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        serverSignatureAlgorithms: [String]?,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    )

    /// The same, plus whether the previous offer partially succeeded (SSH_MSG_USERAUTH_FAILURE with
    /// `partial success` set, RFC 4252 §5.1): the server accepted it but requires one of `availableMethods` as well.
    /// `false` on the first call and after a plain rejection. This is the variant NIOSSH calls; the default
    /// implementation drops `partialSuccess` and calls the variant above.
    ///
    /// Implement it for multi-step authentication, or to know that a key was accepted with the signature
    /// algorithm just offered (so the same key is not offered again under another algorithm).
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        serverSignatureAlgorithms: [String]?,
        partialSuccess: Bool,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    )
}

extension NIOSSHClientUserAuthenticationDelegate {
    public func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        serverSignatureAlgorithms: [String]?,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        self.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: nextChallengePromise)
    }

    public func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        serverSignatureAlgorithms: [String]?,
        partialSuccess: Bool,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        self.nextAuthenticationType(
            availableMethods: availableMethods,
            serverSignatureAlgorithms: serverSignatureAlgorithms,
            nextChallengePromise: nextChallengePromise
        )
    }
}
