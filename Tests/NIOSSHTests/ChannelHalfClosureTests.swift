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

/// Half-closure end to end: the peer sends EOF first, we keep writing and then send ours.
final class ChannelHalfClosureTests: XCTestCase {
    func testWritesAndEOFAfterThePeersEOF() throws {
        let channel = BackToBackEmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish()) }

        let serverReads = ReadRecordingHandler()
        let serverEOF = EOFRecorder()
        let serverErrors = ErrorLoggingHandler()
        var serverChild: Channel?

        let clientHandler = NIOSSHHandler(
            role: .client(
                .init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())
            ),
            allocator: channel.client.allocator,
            inboundChildChannelInitializer: nil
        )
        let serverHandler = NIOSSHHandler(
            role: .server(
                .init(hostKeys: [.init(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 0))
            ),
            allocator: channel.server.allocator
        ) { child, _ in
            serverChild = child
            return child.eventLoop.makeCompletedFuture {
                try child.syncOptions!.setOption(.allowRemoteHalfClosure, value: true)
                try child.pipeline.syncOperations.addHandlers([serverReads, serverEOF, serverErrors])
            }
        }
        XCTAssertNoThrow(try channel.client.pipeline.syncOperations.addHandler(clientHandler))
        XCTAssertNoThrow(try channel.server.pipeline.syncOperations.addHandler(serverHandler))
        XCTAssertNoThrow(try channel.activate())
        XCTAssertNoThrow(try channel.interactInMemory())

        let clientEOF = EOFRecorder()
        let clientErrors = ErrorLoggingHandler()
        let clientChildPromise = channel.client.eventLoop.makePromise(of: Channel.self)
        clientHandler.createChannel(clientChildPromise) { child, _ in
            child.eventLoop.makeCompletedFuture {
                try child.syncOptions!.setOption(.allowRemoteHalfClosure, value: true)
                try child.pipeline.syncOperations.addHandlers([clientEOF, clientErrors])
            }
        }
        XCTAssertNoThrow(try channel.interactInMemory())
        let clientChild = try clientChildPromise.futureResult.wait()
        guard let serverChild = serverChild else {
            XCTFail("No server channel")
            return
        }

        // The server is done talking first.
        XCTAssertNoThrow(try serverChild.close(mode: .output).wait())
        XCTAssertNoThrow(try channel.interactInMemory())
        XCTAssertTrue(clientEOF.seenEOF)
        XCTAssertTrue(clientChild.isActive)

        // The client still has things to say, then says EOF.
        var payload = clientChild.allocator.buffer(capacity: 16)
        payload.writeString("still talking")
        let write = clientChild.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(payload)))
        let eof = clientChild.close(mode: .output)
        XCTAssertNoThrow(try channel.interactInMemory())
        XCTAssertNoThrow(try write.wait())
        XCTAssertNoThrow(try eof.wait())
        XCTAssertEqual(serverReads.reads, [SSHChannelData(type: .channel, data: .byteBuffer(payload))])
        XCTAssertTrue(serverEOF.seenEOF)
        XCTAssertTrue(clientChild.isActive)

        // Both sides are quiescent: a clean close, no errors anywhere.
        let close = clientChild.close()
        XCTAssertNoThrow(try channel.interactInMemory())
        XCTAssertNoThrow(try close.wait())
        XCTAssertNoThrow(try clientChild.closeFuture.wait())
        XCTAssertNoThrow(try serverChild.closeFuture.wait())
        XCTAssertEqual(clientErrors.errors.count, 0)
        XCTAssertEqual(serverErrors.errors.count, 0)
    }
}
