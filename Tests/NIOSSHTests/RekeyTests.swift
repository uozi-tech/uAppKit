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

/// Accepts the first host key at once and holds every later validation (rekeys) until told to complete it.
final class HoldRekeyHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private var validations = 0
    private(set) var pending: EventLoopPromise<Void>?

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        self.validations += 1
        if self.validations == 1 {
            validationCompletePromise.succeed(())
        } else {
            self.pending = validationCompletePromise
        }
    }

    func complete() {
        self.pending?.succeed(())
        self.pending = nil
    }
}

/// A server global request delegate that holds TCP forwarding requests until told to answer them.
final class HeldForwardingDelegate: GlobalRequestDelegate {
    private(set) var pending: EventLoopPromise<GlobalRequest.TCPForwardingResponse>?

    func tcpForwardingRequest(
        _ request: GlobalRequest.TCPForwardingRequest,
        handler: NIOSSHHandler,
        promise: EventLoopPromise<GlobalRequest.TCPForwardingResponse>
    ) {
        self.pending = promise
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

    // MARK: Global requests during a key exchange

    /// The result of `future` if it has completed, without blocking (an embedded loop would hang in `wait()`).
    private func completed<T>(_ future: EventLoopFuture<T>) -> Result<T, Error>? {
        var result: Result<T, Error>?
        future.whenComplete { result = $0 }
        return result
    }

    private func keepalive(from handler: NIOSSHHandler, on loop: EventLoop) -> NIOLoopBoundBox<Result<GlobalRequest.GenericResponse, Error>?> {
        let box = NIOLoopBoundBox<Result<GlobalRequest.GenericResponse, Error>?>(nil, eventLoop: loop)
        let promise = loop.makePromise(of: GlobalRequest.GenericResponse.self)
        promise.futureResult.whenComplete { box.value = $0 }
        handler.sendGlobalRequest(type: "keepalive@openssh.com", payload: nil, wantReply: true, promise: promise)
        return box
    }

    func testPeerGlobalRequestAfterOurKEXINITIsAnsweredAfterTheExchange() throws {
        let (client, _) = try self.connect()

        // We start a rekey; the peer's keepalive (want reply) crossed our KEXINIT on the wire.
        XCTAssertNoThrow(try self.channel.clientSSHHandler!._rekey())
        let answer = self.keepalive(from: self.channel.serverSSHHandler!, on: self.channel.server.eventLoop)
        XCTAssertNoThrow(try self.deliverServerToClient())
        XCTAssertNoThrow(try self.channel.interactInMemory())

        XCTAssertEqual(try answer.value?.get(), .failure)
        let write = self.send("still alive", on: client)
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNoThrow(try self.completed(write)?.get())
        XCTAssertEqual(String(buffer: self.serverReceived.bytes), "still alive")
    }

    func testPeerGlobalRequestAfterThePeersNEWKEYSIsAnsweredAfterOurs() throws {
        let hostKeys = HoldRekeyHostKeyDelegate()
        _ = try self.connect(client: { $0.serverAuthDelegate = hostKeys })

        // Rekey; the client holds host key validation, so it has the server's NEWKEYS but has not sent its own.
        XCTAssertNoThrow(try self.channel.clientSSHHandler!._rekey())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNotNil(hostKeys.pending)
        // The server may send again (it sent NEWKEYS); its keepalive reaches a client that may not answer yet.
        let answer = self.keepalive(from: self.channel.serverSSHHandler!, on: self.channel.server.eventLoop)
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNil(answer.value)

        hostKeys.complete()
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(try answer.value?.get(), .failure)
    }

    func testOurOwnAsyncReplyCompletingMidRekeyWaits() throws {
        let forwarding = HeldForwardingDelegate()
        _ = try self.connect(server: { $0.globalRequestDelegate = forwarding })

        let response = self.channel.client.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        self.channel.clientSSHHandler!.sendTCPForwardingRequest(.listen(host: "localhost", port: 0), promise: response)
        XCTAssertNoThrow(try self.channel.interactInMemory())
        let held = try XCTUnwrap(forwarding.pending)

        // The server starts a rekey, then its delegate answers the forwarding request: the reply must wait.
        XCTAssertNoThrow(try self.channel.serverSSHHandler!._rekey())
        held.succeed(.init(boundPort: 2222))
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(try self.completed(response.futureResult)?.get(), .init(boundPort: 2222))
    }

    /// Starts a client rekey that stops with the server's NEWKEYS received and the client's own NEWKEYS held back by
    /// host key validation.
    private func rekeyHeldAtHostKeyValidation(_ hostKeys: HoldRekeyHostKeyDelegate) throws {
        XCTAssertNoThrow(try self.channel.clientSSHHandler!._rekey())
        try self.channel.interactInMemory()
        XCTAssertNotNil(hostKeys.pending)
    }

    func testGlobalRequestQueuedDuringARekeyGoesOutWhenItCompletesOnAnIdleLink() throws {
        let hostKeys = HoldRekeyHostKeyDelegate()
        _ = try self.connect(client: { $0.serverAuthDelegate = hostKeys })
        try self.rekeyHeldAtHostKeyValidation(hostKeys)

        let answer = self.keepalive(from: self.channel.clientSSHHandler!, on: self.channel.client.eventLoop)
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNil(answer.value)

        // Validation completes outside any read, and nothing else is going on: the keepalive must still go out.
        hostKeys.complete()
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertEqual(try answer.value?.get(), .failure)
    }

    func testChannelOpenedDuringARekeyGoesOutWhenItCompletes() throws {
        let hostKeys = HoldRekeyHostKeyDelegate()
        _ = try self.connect(client: { $0.serverAuthDelegate = hostKeys })
        try self.rekeyHeldAtHostKeyValidation(hostKeys)

        let opened = self.channel.client.eventLoop.makePromise(of: Channel.self)
        self.channel.clientSSHHandler!.createChannel(opened) { channel, _ in channel.eventLoop.makeSucceededVoidFuture() }
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNil(self.completed(opened.futureResult))

        hostKeys.complete()
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNotNil(try self.completed(opened.futureResult)?.get())
    }

    func testDataQueuedAroundAGlobalRequestKeepsItsOrder() throws {
        let hostKeys = HoldRekeyHostKeyDelegate()
        let (client, _) = try self.connect(client: { $0.serverAuthDelegate = hostKeys })
        try self.rekeyHeldAtHostKeyValidation(hostKeys)

        // Data, a keepalive and more data, all queued during the exchange.
        let first = self.send("first ", on: client)
        let answer = self.keepalive(from: self.channel.clientSSHHandler!, on: self.channel.client.eventLoop)
        let second = self.send("second", on: client)
        hostKeys.complete()
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNotNil(try self.completed(first)?.get())
        XCTAssertNotNil(try self.completed(second)?.get())
        XCTAssertEqual(try answer.value?.get(), .failure)
        XCTAssertEqual(String(buffer: self.serverReceived.bytes), "first second")
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

    func testTrafficLimitReachedWhileSendingQueuedGlobalRequestsHoldsTheRest() throws {
        let hostKeys = HoldRekeyHostKeyDelegate()
        _ = try self.connect(
            client: {
                self.useKeyCheckingProtection(&$0)
                $0.serverAuthDelegate = hostKeys
                $0.rekeyLimits = .init(packets: 3, bytes: nil)
            },
            server: {
                self.useKeyCheckingProtection(&$0)
                $0.rekeyLimits = .disabled
            }
        )
        // Logging in already crossed the limit: that exchange is under way, held at host key validation.
        let exchanges = self.keyExchangeCount()
        if hostKeys.pending == nil {
            XCTAssertTrue(self.channel.clientSSHHandler!.rekey())
            XCTAssertNoThrow(try self.channel.interactInMemory())
        }
        XCTAssertNotNil(hostKeys.pending)
        let answers = (0..<8).map { _ in
            self.keepalive(from: self.channel.clientSSHHandler!, on: self.channel.client.eventLoop)
        }

        // Our NEWKEYS goes out with the server's already in: the queued requests go out while active, and the third
        // one reaches the limit and starts the next exchange. The rest wait for that one instead of failing.
        // (Every exchange after the first holds host key validation; let each through.)
        for _ in 0..<8 where hostKeys.pending != nil {
            hostKeys.complete()
            XCTAssertNoThrow(try self.channel.interactInMemory())
        }
        for answer in answers {
            XCTAssertEqual(try answer.value?.get(), .failure)
        }
        XCTAssertGreaterThanOrEqual(self.keyExchangeCount(), exchanges + 2)
    }
}
