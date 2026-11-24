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

/// Records the data a child channel receives.
final class DataRecorder: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private(set) var bytes = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(var buffer) = self.unwrapInboundIn(data).data else {
            return
        }
        self.bytes.writeBuffer(&buffer)
    }
}

final class RekeyTests: XCTestCase {
    private var channel: BackToBackEmbeddedChannel!
    private var serverReceived = DataRecorder()
    private var serverChild: Channel?

    override func setUp() {
        super.setUp()
        self.channel = BackToBackEmbeddedChannel()
        self.serverReceived = DataRecorder()
        self.serverChild = nil
        KeyCheckingTransportProtection.instances = []
    }

    override func tearDown() {
        try? self.channel.finish()
        self.channel = nil
        KeyCheckingTransportProtection.instances = []
        super.tearDown()
    }

    private func connect(
        client: (inout SSHClientConfiguration) -> Void = { _ in },
        server: (inout SSHServerConfiguration) -> Void = { _ in }
    ) throws -> (client: Channel, received: DataRecorder) {
        var clientConfiguration = SSHClientConfiguration(
            userAuthDelegate: InfinitePasswordDelegate(),
            serverAuthDelegate: AcceptAllHostKeysDelegate()
        )
        client(&clientConfiguration)
        var serverConfiguration = SSHServerConfiguration(
            hostKeys: [.init(ed25519Key: .init())],
            userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 0)
        )
        server(&serverConfiguration)
        let recorder = self.serverReceived
        try self.channel.client.pipeline.syncOperations.addHandler(
            NIOSSHHandler(
                role: .client(clientConfiguration),
                allocator: self.channel.client.allocator,
                inboundChildChannelInitializer: nil
            )
        )
        try self.channel.server.pipeline.syncOperations.addHandler(
            NIOSSHHandler(role: .server(serverConfiguration), allocator: self.channel.server.allocator) { child, _ in
                self.serverChild = child
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(recorder)
                }
            }
        )
        try self.channel.activate()
        try self.channel.interactInMemory()

        let clientReceived = DataRecorder()
        let promise = self.channel.client.eventLoop.makePromise(of: Channel.self)
        self.channel.clientSSHHandler!.createChannel(promise) { child, _ in
            child.eventLoop.makeCompletedFuture {
                try child.pipeline.syncOperations.addHandler(clientReceived)
            }
        }
        try self.channel.interactInMemory()
        return (try promise.futureResult.wait(), clientReceived)
    }

    private func send(_ string: String, on child: Channel) -> EventLoopFuture<Void> {
        var buffer = child.allocator.buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        return child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    }

    /// Delivers whatever the server has queued to the client, and nothing the other way.
    private func deliverServerToClient() throws {
        self.channel.run()
        while let data = try self.channel.server.readOutbound(as: IOData.self) {
            try self.channel.client.writeInbound(data)
        }
    }

    // MARK: Writes while a key exchange is in flight

    func testChildWritesDuringAPeerInitiatedRekeyAreQueued() throws {
        let (client, _) = try self.connect()

        // The server starts a rekey; the client sees its KEXINIT and answers with its own, so it is now mid key
        // exchange, and must not send channel data until its NEWKEYS is out (RFC 4253 §7.1).
        XCTAssertNoThrow(try self.channel.serverSSHHandler!._rekey())
        XCTAssertNoThrow(try self.deliverServerToClient())
        let write = self.send("during rekey", on: client)

        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNoThrow(try write.wait())
        XCTAssertEqual(String(buffer: self.serverReceived.bytes), "during rekey")
    }

    func testChildWritesDuringOurOwnRekeyKeepTheirOrder() throws {
        let (client, clientReceived) = try self.connect()

        let before = self.send("one ", on: client)
        XCTAssertNoThrow(try self.channel.clientSSHHandler!._rekey())
        let during = [self.send("two ", on: client), self.send("three", on: client)]
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNoThrow(try before.wait())
        for write in during {
            XCTAssertNoThrow(try write.wait())
        }
        XCTAssertEqual(String(buffer: self.serverReceived.bytes), "one two three")

        // And the other direction, during a rekey the server started.
        let serverChild = try XCTUnwrap(self.serverChild)
        XCTAssertNoThrow(try self.channel.serverSSHHandler!._rekey())
        let reply = self.send("reply", on: serverChild)
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNoThrow(try reply.wait())
        XCTAssertEqual(String(buffer: clientReceived.bytes), "reply")
    }

    func testQueuedWritesFailWhenTheConnectionGoesAway() throws {
        let (client, _) = try self.connect()
        XCTAssertNoThrow(try self.channel.clientSSHHandler!._rekey())
        let write = self.send("never sent", on: client)
        let failure = NIOLoopBoundBox<Error?>(nil, eventLoop: self.channel.client.eventLoop)
        write.whenFailure { failure.value = $0 }

        self.channel.client.close(promise: nil)
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNotNil(failure.value)
        XCTAssertEqual(self.serverReceived.bytes.readableBytes, 0)
    }

    // MARK: Rekeying on demand and after a traffic limit

    private func keyExchangeCount() -> Int {
        // One protection instance per side per key exchange.
        KeyCheckingTransportProtection.instances.count / 2
    }

    private func useKeyCheckingProtection(_ configuration: inout SSHClientConfiguration) {
        configuration.transportProtectionSchemes = [KeyCheckingTransportProtection.self]
    }

    private func useKeyCheckingProtection(_ configuration: inout SSHServerConfiguration) {
        configuration.transportProtectionSchemes = [KeyCheckingTransportProtection.self]
    }

    private func exchange(_ count: Int, client: Channel, prefix: String = "") throws {
        let serverChild = try XCTUnwrap(self.serverChild)
        for i in 0..<count {
            _ = self.send("c\(prefix)\(i);", on: client)
            _ = self.send("s\(prefix)\(i);", on: serverChild)
            try self.channel.interactInMemory()
        }
    }

    private func expected(_ side: String, _ count: Int, prefix: String = "") -> String {
        (0..<count).map { "\(side)\(prefix)\($0);" }.joined()
    }

    func testRekeyOnDemand() throws {
        let (client, clientReceived) = try self.connect(
            client: { self.useKeyCheckingProtection(&$0) },
            server: { self.useKeyCheckingProtection(&$0) }
        )
        XCTAssertEqual(self.keyExchangeCount(), 1)
        XCTAssertTrue(self.channel.clientSSHHandler!.rekey())
        // A second request while the first is in flight does nothing.
        XCTAssertFalse(self.channel.clientSSHHandler!.rekey())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(self.keyExchangeCount(), 2)
        XCTAssertNoThrow(try self.exchange(3, client: client))
        XCTAssertEqual(String(buffer: self.serverReceived.bytes), self.expected("c", 3))
        XCTAssertEqual(String(buffer: clientReceived.bytes), self.expected("s", 3))
    }

    func testPacketLimitTriggersRekeysAndDataKeepsFlowing() throws {
        let (client, clientReceived) = try self.connect(
            client: {
                self.useKeyCheckingProtection(&$0)
                $0.rekeyLimits = .init(packets: 10, bytes: nil)
            },
            server: {
                self.useKeyCheckingProtection(&$0)
                $0.rekeyLimits = .disabled
            }
        )
        XCTAssertNoThrow(try self.exchange(40, client: client))
        XCTAssertEqual(String(buffer: self.serverReceived.bytes), self.expected("c", 40))
        XCTAssertEqual(String(buffer: clientReceived.bytes), self.expected("s", 40))
        // 40 packets each way at a limit of 10: a handful of rekeys, each resetting the count.
        XCTAssertGreaterThanOrEqual(self.keyExchangeCount(), 4)
        XCTAssertLessThanOrEqual(self.keyExchangeCount(), 10)
    }

    func testByteLimitTriggersARekey() throws {
        let (client, clientReceived) = try self.connect(
            client: {
                self.useKeyCheckingProtection(&$0)
                $0.rekeyLimits = .disabled
            },
            server: {
                self.useKeyCheckingProtection(&$0)
                $0.rekeyLimits = .init(packets: nil, bytes: 4096)
            }
        )
        let serverChild = try XCTUnwrap(self.serverChild)
        let chunk = String(repeating: "x", count: 1000)
        for _ in 0..<10 {
            _ = self.send(chunk, on: serverChild)
            XCTAssertNoThrow(try self.channel.interactInMemory())
        }
        XCTAssertEqual(clientReceived.bytes.readableBytes, 10_000)
        XCTAssertGreaterThanOrEqual(self.keyExchangeCount(), 2)
        _ = client
    }

    func testBothSidesRekeyingAtOnce() throws {
        let (client, clientReceived) = try self.connect(
            client: {
                self.useKeyCheckingProtection(&$0)
                $0.rekeyLimits = .init(packets: 8, bytes: nil)
            },
            server: {
                self.useKeyCheckingProtection(&$0)
                $0.rekeyLimits = .init(packets: 8, bytes: nil)
            }
        )
        // Both sides cross their limits on the same packets and send KEXINIT before seeing the other's.
        let serverChild = try XCTUnwrap(self.serverChild)
        for i in 0..<30 {
            _ = self.send("c\(i);", on: client)
            _ = self.send("s\(i);", on: serverChild)
            XCTAssertNoThrow(try self.channel.interactInMemory())
        }
        XCTAssertEqual(String(buffer: self.serverReceived.bytes), self.expected("c", 30))
        XCTAssertEqual(String(buffer: clientReceived.bytes), self.expected("s", 30))
        XCTAssertGreaterThanOrEqual(self.keyExchangeCount(), 3)
    }

    func testSimultaneousRekeyRequests() throws {
        let (client, clientReceived) = try self.connect(
            client: { self.useKeyCheckingProtection(&$0) },
            server: { self.useKeyCheckingProtection(&$0) }
        )
        // Both KEXINITs are on the wire before either side has read the other's.
        XCTAssertTrue(self.channel.clientSSHHandler!.rekey())
        XCTAssertTrue(self.channel.serverSSHHandler!.rekey())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(self.keyExchangeCount(), 2, "one exchange, not two")
        XCTAssertNoThrow(try self.exchange(3, client: client))
        XCTAssertEqual(String(buffer: clientReceived.bytes), self.expected("s", 3))
    }

    func testDisabledLimitsNeverRekey() throws {
        let (client, _) = try self.connect(
            client: {
                self.useKeyCheckingProtection(&$0)
                $0.rekeyLimits = .disabled
            },
            server: {
                self.useKeyCheckingProtection(&$0)
                $0.rekeyLimits = .disabled
            }
        )
        XCTAssertNoThrow(try self.exchange(50, client: client))
        XCTAssertEqual(self.keyExchangeCount(), 1)
        XCTAssertEqual(String(buffer: self.serverReceived.bytes), self.expected("c", 50))
    }

    func testCountersRestartWithEveryKeyExchange() throws {
        // Connection setup sends 3 packets each way; 12 writes more would cross 20 without a reset in between.
        let (client, _) = try self.connect(
            client: {
                self.useKeyCheckingProtection(&$0)
                $0.rekeyLimits = .init(packets: 20, bytes: nil)
            },
            server: {
                self.useKeyCheckingProtection(&$0)
                $0.rekeyLimits = .disabled
            }
        )
        XCTAssertNoThrow(try self.exchange(9, client: client))
        XCTAssertEqual(self.keyExchangeCount(), 1)
        XCTAssertTrue(self.channel.clientSSHHandler!.rekey())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNoThrow(try self.exchange(15, client: client, prefix: "b"))
        XCTAssertEqual(self.keyExchangeCount(), 2)
        XCTAssertEqual(
            String(buffer: self.serverReceived.bytes),
            self.expected("c", 9) + self.expected("c", 15, prefix: "b")
        )
    }

    func testDefaultLimits() {
        let client = SSHClientConfiguration(
            userAuthDelegate: InfinitePasswordDelegate(),
            serverAuthDelegate: AcceptAllHostKeysDelegate()
        )
        XCTAssertEqual(client.rekeyLimits, NIOSSHRekeyLimits(packets: 1 << 31, bytes: 1 << 30))
        let server = SSHServerConfiguration(hostKeys: [], userAuthDelegate: DenyAllServerAuthDelegate())
        XCTAssertEqual(server.rekeyLimits, .default)
        XCTAssertFalse(NIOSSHRekeyLimits.disabled.isReached(by: .init(packets: .max, bytes: .max)))
        XCTAssertTrue(NIOSSHRekeyLimits.default.isReached(by: .init(packets: 1 << 31, bytes: 0)))
        XCTAssertTrue(NIOSSHRekeyLimits.default.isReached(by: .init(packets: 0, bytes: 1 << 30)))
        XCTAssertFalse(NIOSSHRekeyLimits.default.isReached(by: .init(packets: (1 << 31) - 1, bytes: (1 << 30) - 1)))
    }
}
