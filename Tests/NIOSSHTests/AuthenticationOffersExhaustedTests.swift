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

/// A client delegate whose offers run out: authentication fails with an error instead of hanging.
final class AuthenticationOffersExhaustedTests: XCTestCase {
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

    final class NothingToOffer: NIOSSHClientUserAuthenticationDelegate {
        func nextAuthenticationType(
            availableMethods: NIOSSHAvailableUserAuthenticationMethods,
            nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
        ) {
            nextChallengePromise.succeed(nil)
        }
    }

    func testNoOfferAtAllFailsAuthentication() throws {
        var harness = TestHarness()
        harness.clientAuthDelegate = NothingToOffer()
        XCTAssertNoThrow(try self.channel.configureWithHarness(harness))
        XCTAssertNoThrow(try self.channel.activate())
        XCTAssertThrowsError(try self.channel.interactInMemory()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .noFurtherAuthenticationOffers)
        }
    }

    func testRejectedLastOfferFailsAuthentication() throws {
        var harness = TestHarness()
        harness.clientAuthDelegate = SimplePasswordDelegate(username: "foo", password: "wrong")
        harness.serverAuthDelegate = DenyThenAcceptDelegate(messagesToDeny: 1)
        XCTAssertNoThrow(try self.channel.configureWithHarness(harness))
        XCTAssertNoThrow(try self.channel.activate())
        XCTAssertThrowsError(try self.channel.interactInMemory()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .noFurtherAuthenticationOffers)
        }
    }

    func testSuccessfulOffersAreUnaffected() throws {
        var harness = TestHarness()
        harness.clientAuthDelegate = SimplePasswordDelegate(username: "foo", password: "right")
        XCTAssertNoThrow(try self.channel.configureWithHarness(harness))
        XCTAssertNoThrow(try self.channel.activate())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        self.channel.clientSSHHandler?.createChannel(nil, nil)
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(self.channel.activeServerChannels.count, 1)
    }
}
