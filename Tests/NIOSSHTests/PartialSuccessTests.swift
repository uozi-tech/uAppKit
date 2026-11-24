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

/// A server that answers the first request with partial success (password still required), then succeeds.
final class PartialThenAcceptDelegate: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .all
    private(set) var requests = 0

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        self.requests += 1
        responsePromise.succeed(self.requests == 1 ? .partialSuccess(remainingMethods: .password) : .success)
    }
}

/// Records what NIOSSH tells it and offers passwords, at most `offers` of them.
final class PartialSuccessRecorder: NIOSSHClientUserAuthenticationDelegate {
    private(set) var calls: [(methods: NIOSSHAvailableUserAuthenticationMethods, partialSuccess: Bool)] = []
    private var offers: Int

    init(offers: Int) {
        self.offers = offers
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        XCTFail("NIOSSH must call the variant with partialSuccess")
        nextChallengePromise.succeed(nil)
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        serverSignatureAlgorithms: [String]?,
        partialSuccess: Bool,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        self.calls.append((availableMethods, partialSuccess))
        guard self.offers > 0 else {
            nextChallengePromise.succeed(nil)
            return
        }
        self.offers -= 1
        nextChallengePromise.succeed(.init(username: "foo", serviceName: "", offer: .password(.init(password: "bar"))))
    }
}

final class PartialSuccessTests: XCTestCase {
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

    private func run(
        client: NIOSSHClientUserAuthenticationDelegate,
        server: NIOSSHServerUserAuthenticationDelegate
    ) throws -> UserAuthSuccessRecorder {
        var harness = TestHarness()
        harness.clientAuthDelegate = client
        harness.serverAuthDelegate = server
        let successes = UserAuthSuccessRecorder()
        try self.channel.configureWithHarness(harness)
        try self.channel.client.pipeline.syncOperations.addHandler(successes)
        try self.channel.activate()
        return successes
    }

    func testPartialSuccessIsPassedOn() throws {
        let recorder = PartialSuccessRecorder(offers: 2)
        let successes = try self.run(client: recorder, server: PartialThenAcceptDelegate())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(successes.successes, 1)
        XCTAssertEqual(recorder.calls.map(\.partialSuccess), [false, true])
        XCTAssertEqual(recorder.calls.last?.methods, .password)
    }

    func testPlainRejectionIsNotPartialSuccess() throws {
        let recorder = PartialSuccessRecorder(offers: 2)
        let successes = try self.run(client: recorder, server: DenyThenAcceptDelegate(messagesToDeny: 1))
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(successes.successes, 1)
        XCTAssertEqual(recorder.calls.map(\.partialSuccess), [false, false])
    }

    func testOlderDelegatesStillWork() throws {
        // Two-argument delegate.
        let successes = try self.run(client: InfinitePasswordDelegate(), server: PartialThenAcceptDelegate())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(successes.successes, 1)

        // Three-argument delegate (server-sig-algs).
        try? self.channel.finish()
        self.channel = BackToBackEmbeddedChannel()
        let recorder = ServerSignatureAlgorithmsRecorder()
        let moreSuccesses = try self.run(client: recorder, server: PartialThenAcceptDelegate())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(moreSuccesses.successes, 1)
        XCTAssertEqual(recorder.calls.count, 2)
    }

    func testNoFurtherOfferAfterPartialSuccessStillFails() throws {
        let recorder = PartialSuccessRecorder(offers: 1)
        let successes = try self.run(client: recorder, server: PartialThenAcceptDelegate())
        XCTAssertThrowsError(try self.channel.interactInMemory()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .noFurtherAuthenticationOffers)
        }
        XCTAssertEqual(recorder.calls.map(\.partialSuccess), [false, true])
        XCTAssertEqual(successes.successes, 0)
    }
}
