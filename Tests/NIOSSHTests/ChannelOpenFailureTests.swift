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
import NIOEmbedded
import XCTest

@testable import NIOSSH

final class ChannelOpenFailureTests: XCTestCase {
    func testReasonCodeIsExposed() {
        let error = NIOSSHError.channelSetupRejected(reasonCode: 1, reason: "administratively prohibited")
        XCTAssertEqual(error.type, .channelSetupRejected)
        XCTAssertEqual(error.channelOpenFailureReasonCode, 1)
        XCTAssertEqual(error.channelOpenFailureDescription, "administratively prohibited")

        XCTAssertNil(NIOSSHError.tcpShutdown.channelOpenFailureReasonCode)
        XCTAssertNil(NIOSSHError.tcpShutdown.channelOpenFailureDescription)
    }

    func testPeerRejectionCarriesTheReasonCode() throws {
        let channel = BackToBackEmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish()) }

        enum Refused: Error { case no }
        let clientHandler = NIOSSHHandler(
            role: .client(
                .init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())
            ),
            allocator: channel.client.allocator,
            inboundChildChannelInitializer: nil
        )
        // The server refuses every channel: NIOSSH answers with SSH_MSG_CHANNEL_OPEN_FAILURE, reason 2.
        let serverHandler = NIOSSHHandler(
            role: .server(
                .init(hostKeys: [.init(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 0))
            ),
            allocator: channel.server.allocator
        ) { child, _ in
            child.eventLoop.makeFailedFuture(Refused.no)
        }
        XCTAssertNoThrow(try channel.client.pipeline.syncOperations.addHandler(clientHandler))
        XCTAssertNoThrow(try channel.server.pipeline.syncOperations.addHandler(serverHandler))
        XCTAssertNoThrow(try channel.activate())
        XCTAssertNoThrow(try channel.interactInMemory())

        let promise = channel.client.eventLoop.makePromise(of: Channel.self)
        clientHandler.createChannel(promise) { child, _ in child.eventLoop.makeSucceededVoidFuture() }
        XCTAssertNoThrow(try channel.interactInMemory())
        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            let error = error as? NIOSSHError
            XCTAssertEqual(error?.type, .channelSetupRejected)
            XCTAssertEqual(error?.channelOpenFailureReasonCode, 2)
            XCTAssertEqual(error?.channelOpenFailureDescription, "")
        }
    }
}
