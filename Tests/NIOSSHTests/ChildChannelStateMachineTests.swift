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
import XCTest

@testable import NIOSSH

final class ChildChannelStateMachineTests: XCTestCase {
    private func activeOutboundChannel() throws -> ChildChannelStateMachine {
        var state = ChildChannelStateMachine(localChannelID: 1)
        state.sendChannelOpen(
            .init(type: .session, senderChannel: 1, initialWindowSize: 1 << 24, maximumPacketSize: 1 << 17)
        )
        try state.receiveChannelOpenConfirmation(
            .init(recipientChannel: 1, senderChannel: 2, initialWindowSize: 1 << 24, maximumPacketSize: 1 << 17)
        )
        return state
    }

    /// `canSendWindowAdjust` must be true exactly where `sendChannelWindowAdjust` does not trap.
    func testCanSendWindowAdjustMatchesSendChannelWindowAdjust() throws {
        let adjust = SSHMessage.ChannelWindowAdjustMessage(recipientChannel: 2, bytesToAdd: 1)

        var idle = ChildChannelStateMachine(localChannelID: 1)
        XCTAssertFalse(idle.canSendWindowAdjust)
        idle.sendChannelOpen(
            .init(type: .session, senderChannel: 1, initialWindowSize: 1 << 24, maximumPacketSize: 1 << 17)
        )
        XCTAssertFalse(idle.canSendWindowAdjust, "requestedLocally")

        var active = try self.activeOutboundChannel()
        XCTAssertTrue(active.canSendWindowAdjust)
        XCTAssertNoThrow(try active.sendChannelWindowAdjust(adjust))

        var halfClosedRemote = try self.activeOutboundChannel()
        try halfClosedRemote.receiveChannelEOF(.init(recipientChannel: 1))
        XCTAssertTrue(halfClosedRemote.canSendWindowAdjust)
        XCTAssertNoThrow(try halfClosedRemote.sendChannelWindowAdjust(adjust))

        var halfClosedLocal = try self.activeOutboundChannel()
        try halfClosedLocal.sendChannelEOF(.init(recipientChannel: 2))
        XCTAssertTrue(halfClosedLocal.canSendWindowAdjust)

        var quiescent = halfClosedLocal
        try quiescent.receiveChannelEOF(.init(recipientChannel: 1))
        XCTAssertTrue(quiescent.canSendWindowAdjust)
        XCTAssertNoThrow(try quiescent.sendChannelWindowAdjust(adjust))

        var closedLocally = try self.activeOutboundChannel()
        try closedLocally.sendChannelClose(.init(recipientChannel: 2))
        XCTAssertFalse(closedLocally.canSendWindowAdjust)

        var closed = closedLocally
        try closed.receiveChannelClose(.init(recipientChannel: 1))
        XCTAssertFalse(closed.canSendWindowAdjust)
    }

    /// The peer closed first: `.closedRemotely`. The upstream guard (`!sentClose`) lets this state through, but
    /// `sendChannelWindowAdjust` would hit a `preconditionFailure` here and abort the process.
    func testClosedRemotelyCannotSendWindowAdjust() throws {
        var state = try self.activeOutboundChannel()
        try state.receiveChannelClose(.init(recipientChannel: 1))

        XCTAssertFalse(state.sentClose, "the gap the old guard left open")
        XCTAssertTrue(state.isActiveOnChannel)
        XCTAssertFalse(state.canSendWindowAdjust)

        // The same after an EOF from the peer.
        var afterEOF = try self.activeOutboundChannel()
        try afterEOF.receiveChannelEOF(.init(recipientChannel: 1))
        try afterEOF.receiveChannelClose(.init(recipientChannel: 1))
        XCTAssertFalse(afterEOF.sentClose)
        XCTAssertFalse(afterEOF.canSendWindowAdjust)
    }

    // MARK: EOF in both directions

    func testEOFOrderings() throws {
        // We send EOF first, then the peer.
        var localFirst = try self.activeOutboundChannel()
        try localFirst.sendChannelEOF(.init(recipientChannel: 2))
        XCTAssertTrue(localFirst.isActiveOnChannel)
        try localFirst.receiveChannelEOF(.init(recipientChannel: 1))
        XCTAssertNoThrow(try localFirst.sendChannelClose(.init(recipientChannel: 2)))

        // The peer sends EOF first, then we do: the end of a `-L` stream whose server half-closes first, or EOF on an
        // exec whose output already ended. Used to throw "Sent EOF out of sequence.".
        var remoteFirst = try self.activeOutboundChannel()
        try remoteFirst.receiveChannelEOF(.init(recipientChannel: 1))
        XCTAssertNoThrow(try remoteFirst.sendChannelData(.init(recipientChannel: 2, data: ByteBuffer())))
        XCTAssertNoThrow(try remoteFirst.sendChannelEOF(.init(recipientChannel: 2)))
        XCTAssertThrowsError(try remoteFirst.sendChannelData(.init(recipientChannel: 2, data: ByteBuffer())))
        XCTAssertThrowsError(try remoteFirst.receiveChannelEOF(.init(recipientChannel: 1)))
        XCTAssertNoThrow(try remoteFirst.sendChannelClose(.init(recipientChannel: 2)))
        XCTAssertNoThrow(try remoteFirst.receiveChannelClose(.init(recipientChannel: 1)))
        XCTAssertTrue(remoteFirst.isClosed)

        // We may send EOF only once...
        var localTwice = try self.activeOutboundChannel()
        try localTwice.sendChannelEOF(.init(recipientChannel: 2))
        XCTAssertThrowsError(try localTwice.sendChannelEOF(.init(recipientChannel: 2))) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }

        // ... and so may the peer.
        var remoteTwice = try self.activeOutboundChannel()
        try remoteTwice.receiveChannelEOF(.init(recipientChannel: 1))
        XCTAssertThrowsError(try remoteTwice.receiveChannelEOF(.init(recipientChannel: 1))) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }

        // Both EOFs sent and received: a third one either way is out of sequence.
        var quiescent = try self.activeOutboundChannel()
        try quiescent.receiveChannelEOF(.init(recipientChannel: 1))
        try quiescent.sendChannelEOF(.init(recipientChannel: 2))
        XCTAssertThrowsError(try quiescent.sendChannelEOF(.init(recipientChannel: 2)))
    }
}
