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
}
