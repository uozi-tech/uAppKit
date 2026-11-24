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

/// A server global request delegate that accepts every TCP forwarding request with a fixed port.
final class AcceptingForwardingDelegate: GlobalRequestDelegate {
    func tcpForwardingRequest(
        _ request: GlobalRequest.TCPForwardingRequest,
        handler: NIOSSHHandler,
        promise: EventLoopPromise<GlobalRequest.TCPForwardingResponse>
    ) {
        promise.succeed(.init(boundPort: 4242))
    }
}

final class GenericGlobalRequestTests: XCTestCase {
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

    private func keepalive(
        wantReply: Bool = true
    ) -> (EventLoopFuture<GlobalRequest.GenericResponse>, NIOLoopBoundBox<Result<GlobalRequest.GenericResponse, Error>?>) {
        let promise = self.channel.client.eventLoop.makePromise(of: GlobalRequest.GenericResponse.self)
        let box = NIOLoopBoundBox<Result<GlobalRequest.GenericResponse, Error>?>(
            nil,
            eventLoop: self.channel.client.eventLoop
        )
        promise.futureResult.whenComplete { box.value = $0 }
        self.channel.clientSSHHandler?.sendGlobalRequest(
            type: "keepalive@openssh.com",
            payload: nil,
            wantReply: wantReply,
            promise: promise
        )
        return (promise.futureResult, box)
    }

    func testKeepaliveIsAnsweredWithFailureByNIOSSHServers() throws {
        XCTAssertNoThrow(try self.channel.configureWithHarness(TestHarness()))
        // Queued before the connection is up; sent once it is.
        let (_, early) = self.keepalive()
        XCTAssertNoThrow(try self.channel.activate())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(try early.value?.get(), .failure)

        // Unknown inbound requests are still refused, and the connection stays usable.
        let (_, again) = self.keepalive()
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(try again.value?.get(), .failure)
        let channelPromise = self.channel.client.eventLoop.makePromise(of: Channel.self)
        self.channel.clientSSHHandler?.createChannel(channelPromise) { channel, _ in channel.eventLoop.makeSucceededVoidFuture() }
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNoThrow(try channelPromise.futureResult.wait())
    }

    func testRequestWithoutReplyCompletesOnceWritten() throws {
        XCTAssertNoThrow(try self.channel.configureWithHarness(TestHarness()))
        XCTAssertNoThrow(try self.channel.activate())
        XCTAssertNoThrow(try self.channel.interactInMemory())

        let (_, noReply) = self.keepalive(wantReply: false)
        let (_, withReply) = self.keepalive(wantReply: true)
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(try noReply.value?.get(), .success(ByteBuffer()))
        // The server's single reply belongs to the second request.
        XCTAssertEqual(try withReply.value?.get(), .failure)
    }

    func testRepliesAreMatchedInOrderWithForwardingRequests() throws {
        var harness = TestHarness()
        harness.serverGlobalRequestDelegate = AcceptingForwardingDelegate()
        XCTAssertNoThrow(try self.channel.configureWithHarness(harness))
        XCTAssertNoThrow(try self.channel.activate())
        XCTAssertNoThrow(try self.channel.interactInMemory())

        let (_, first) = self.keepalive()
        let forwarding = self.channel.client.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        self.channel.clientSSHHandler?.sendTCPForwardingRequest(.listen(host: "localhost", port: 0), promise: forwarding)
        let (_, last) = self.keepalive()
        XCTAssertNoThrow(try self.channel.interactInMemory())

        XCTAssertEqual(try first.value?.get(), .failure)
        XCTAssertEqual(try forwarding.futureResult.wait(), .init(boundPort: 4242))
        XCTAssertEqual(try last.value?.get(), .failure)
    }

    func testPendingRequestFailsWhenTheConnectionCloses() throws {
        XCTAssertNoThrow(try self.channel.configureWithHarness(TestHarness()))
        XCTAssertNoThrow(try self.channel.activate())
        XCTAssertNoThrow(try self.channel.interactInMemory())

        let (_, pending) = self.keepalive()
        XCTAssertNil(pending.value)
        self.channel.client.close(promise: nil)
        XCTAssertNoThrow(try self.channel.interactInMemory())
        guard case .some(.failure(let error)) = pending.value else {
            XCTFail("Expected a failure, got \(String(describing: pending.value))")
            return
        }
        XCTAssertEqual(error as? ChannelError, .eof)
    }

    func testSuccessCarriesThePayload() {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: GlobalRequest.GenericResponse.self)
        NIOSSHHandler.PendingGlobalRequestResponse.generic(promise)
            .succeed(.init(buffer: ByteBuffer(bytes: [1, 2, 3])))
        XCTAssertEqual(try promise.futureResult.wait(), .success(ByteBuffer(bytes: [1, 2, 3])))

        let refused = loop.makePromise(of: GlobalRequest.GenericResponse.self)
        NIOSSHHandler.PendingGlobalRequestResponse.generic(refused).refuse()
        XCTAssertEqual(try refused.futureResult.wait(), .failure)
        XCTAssertNoThrow(try loop.syncShutdownGracefully())
    }
}
