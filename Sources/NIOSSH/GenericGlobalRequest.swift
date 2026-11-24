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

import NIOCore

extension GlobalRequest {
    /// The peer's answer to a global request sent with `NIOSSHHandler.sendGlobalRequest(type:payload:wantReply:promise:)`.
    public enum GenericResponse: Hashable, Sendable {
        /// SSH_MSG_REQUEST_SUCCESS, with the request-specific data that followed the message number (often empty).
        /// A request sent with `wantReply: false` completes with `.success` and an empty payload once it is written.
        case success(ByteBuffer)

        /// SSH_MSG_REQUEST_FAILURE: the peer refused or did not understand the request.
        case failure
    }
}

extension NIOSSHHandler {
    /// Sends a global request of any type (RFC 4254 §4), e.g. `keepalive@openssh.com` with `wantReply: true`:
    /// both possible replies prove the peer is alive.
    ///
    /// Requests are sent once the connection is active, in order with the other global requests (TCP forwarding
    /// ones included), and replies are matched in that order. The promise fails only if the request could not be
    /// sent or the connection closed before the reply arrived; a refusal is `.failure`, not an error.
    ///
    /// This function is **not** thread-safe: it may only be called from on the channel.
    ///
    /// - parameters:
    ///     - type: The request name, e.g. `keepalive@openssh.com`.
    ///     - payload: The request-specific data after `want reply`, or `nil` for none.
    ///     - wantReply: Whether the peer must answer.
    ///     - promise: Completed with the answer.
    public func sendGlobalRequest(
        type: String,
        payload: ByteBuffer?,
        wantReply: Bool,
        promise: EventLoopPromise<GlobalRequest.GenericResponse>? = nil
    ) {
        let message = SSHMessage.GlobalRequestMessage(
            wantReply: wantReply,
            type: .unknown(type, payload ?? ByteBuffer())
        )
        self.sendGlobalRequest(message, response: promise.map { .generic($0) })
    }
}
