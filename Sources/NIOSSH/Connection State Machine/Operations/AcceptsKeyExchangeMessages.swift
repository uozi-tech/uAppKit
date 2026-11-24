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

protocol AcceptsKeyExchangeMessages {
    var keyExchangeStateMachine: SSHKeyExchangeStateMachine { get set }

    var parser: SSHPacketParser { get set }
}

extension AcceptsKeyExchangeMessages {
    mutating func receiveKeyExchangeMessage(
        _ message: SSHMessage.KeyExchangeMessage
    ) throws -> SSHConnectionStateMachine.StateMachineInboundProcessResult {
        let message = try self.keyExchangeStateMachine.handle(keyExchange: message)

        // Strict key exchange: the peer's KEXINIT must have been its first packet.
        if self.keyExchangeStateMachine.isStrictKeyExchange, self.parser.sequenceNumber != 1 {
            throw NIOSSHError.protocolViolation(
                protocolName: "key exchange",
                violation: "strict KEX violation: KEXINIT was not the first packet"
            )
        }

        if let message = message {
            return .emitMessage(message)
        } else {
            return .noMessage
        }
    }

    mutating func receiveKeyExchangeInitMessage(
        _ message: SSHMessage.KeyExchangeECDHInitMessage
    ) throws -> SSHConnectionStateMachine.StateMachineInboundProcessResult {
        let message = try self.keyExchangeStateMachine.handle(keyExchangeInit: message)

        if let message = message {
            return .emitMessage(message)
        } else {
            return .noMessage
        }
    }

    mutating func receiveKeyExchangeReplyMessage(
        _ message: SSHMessage.KeyExchangeECDHReplyMessage
    ) throws -> SSHConnectionStateMachine.StateMachineInboundProcessResult {
        let message = try self.keyExchangeStateMachine.handle(keyExchangeReply: message)
        return .possibleFutureMessage(message)
    }

    mutating func receiveNewKeysMessage() throws {
        // Received a new keys message. Apply the encryption keys to the parser.
        let result = try self.keyExchangeStateMachine.handleNewKeys()
        self.parser.addEncryption(result, strictKeyExchange: self.keyExchangeStateMachine.isStrictKeyExchange)
    }

    /// Strict key exchange: during the initial key exchange only key exchange messages are allowed, not even
    /// SSH_MSG_IGNORE or SSH_MSG_DEBUG.
    func validateNonKeyExchangeMessage(_ message: SSHMessage) throws {
        if self.keyExchangeStateMachine.isStrictKeyExchange {
            throw NIOSSHError.protocolViolation(
                protocolName: "key exchange",
                violation: "strict KEX violation: unexpected message during initial key exchange: \(message)"
            )
        }
    }
}
