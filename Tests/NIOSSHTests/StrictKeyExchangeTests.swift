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

import Crypto
import NIOCore
import NIOEmbedded
import XCTest

@testable import NIOSSH

/// Strict key exchange (OpenSSH PROTOCOL §1.10, the Terrapin mitigation, CVE-2023-48795).
final class StrictKeyExchangeTests: XCTestCase {
    private var channel: BackToBackEmbeddedChannel!

    override func setUp() {
        super.setUp()
        self.channel = BackToBackEmbeddedChannel()
        KeyCheckingTransportProtection.instances = []
        NIOSSHAlgorithms._unregisterAllKeyExchangeAlgorithms()
    }

    override func tearDown() {
        try? self.channel.finish()
        self.channel = nil
        KeyCheckingTransportProtection.instances = []
        NIOSSHAlgorithms._unregisterAllKeyExchangeAlgorithms()
        super.tearDown()
    }

    private struct Options {
        var clientStrict = true
        var serverStrict = true
        var keyExchange: [String]? = nil
        var protections: [NIOSSHTransportProtection.Type] = Constants.bundledTransportProtectionSchemes
    }

    private func configure(_ options: Options) throws {
        var client = SSHClientConfiguration(
            userAuthDelegate: InfinitePasswordDelegate(),
            serverAuthDelegate: AcceptAllHostKeysDelegate(),
            transportProtectionSchemes: options.protections
        )
        client.offersStrictKeyExchange = options.clientStrict
        var server = SSHServerConfiguration(
            hostKeys: [.init(ed25519Key: .init())],
            userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 0),
            transportProtectionSchemes: options.protections
        )
        server.offersStrictKeyExchange = options.serverStrict
        if let keyExchange = options.keyExchange {
            client.keyExchangeAlgorithms = keyExchange
            server.keyExchangeAlgorithms = keyExchange
        }
        let clientHandler = NIOSSHHandler(
            role: .client(client),
            allocator: self.channel.client.allocator,
            inboundChildChannelInitializer: nil
        )
        let serverHandler = NIOSSHHandler(role: .server(server), allocator: self.channel.server.allocator) {
            channel,
            _ in
            channel.eventLoop.makeSucceededVoidFuture()
        }
        try self.channel.client.pipeline.syncOperations.addHandler(clientHandler)
        try self.channel.server.pipeline.syncOperations.addHandler(serverHandler)
        try self.channel.activate()
    }

    private func openChannel() throws -> Bool {
        let promise = self.channel.client.eventLoop.makePromise(of: Channel.self)
        self.channel.clientSSHHandler?.createChannel(promise) { channel, _ in
            channel.eventLoop.makeSucceededVoidFuture()
        }
        try self.channel.interactInMemory()
        return (try? promise.futureResult.wait())?.isActive ?? false
    }

    /// The first sequence number each protection instance saw in each direction.
    private func firstSequenceNumbers() -> [(outbound: UInt32?, inbound: UInt32?)] {
        KeyCheckingTransportProtection.instances.map { instance in
            let outbound = instance.events.lazy.compactMap { event -> UInt32? in
                if case .outbound(let n) = event { return n } else { return nil }
            }.first
            let inbound = instance.events.lazy.compactMap { event -> UInt32? in
                if case .inbound(let n) = event { return n } else { return nil }
            }.first
            return (outbound, inbound)
        }
    }

    // MARK: KEXINIT contents

    private func keyExchangeMessage(
        role: SSHConnectionRole,
        previousSessionIdentifier: ByteBuffer?
    ) -> SSHMessage.KeyExchangeMessage {
        SSHKeyExchangeStateMachine(
            allocator: ByteBufferAllocator(),
            loop: EmbeddedEventLoop(),
            role: role,
            remoteVersion: Constants.version,
            protectionSchemes: [AES256GCMOpenSSHTransportProtection.self],
            previousSessionIdentifier: previousSessionIdentifier
        ).createKeyExchangeMessage()
    }

    func testMarkerIsAppendedToTheFirstKeyExchangeOnly() {
        var clientConfiguration = SSHClientConfiguration(
            userAuthDelegate: InfinitePasswordDelegate(),
            serverAuthDelegate: AcceptAllHostKeysDelegate()
        )
        let serverConfiguration = SSHServerConfiguration(
            hostKeys: [.init(ed25519Key: .init())],
            userAuthDelegate: DenyAllServerAuthDelegate()
        )
        let defaults = SSHKeyExchangeStateMachine.supportedKeyExchangeAlgorithms

        let clientFirst = self.keyExchangeMessage(role: .client(clientConfiguration), previousSessionIdentifier: nil)
        XCTAssertEqual(clientFirst.keyExchangeAlgorithms, defaults + ["kex-strict-c-v00@openssh.com"])
        let serverFirst = self.keyExchangeMessage(role: .server(serverConfiguration), previousSessionIdentifier: nil)
        XCTAssertEqual(serverFirst.keyExchangeAlgorithms, defaults + ["kex-strict-s-v00@openssh.com"])

        // Rekeys never carry it.
        let session = ByteBuffer(bytes: [1, 2, 3])
        XCTAssertEqual(
            self.keyExchangeMessage(role: .client(clientConfiguration), previousSessionIdentifier: session)
                .keyExchangeAlgorithms,
            defaults
        )
        XCTAssertEqual(
            self.keyExchangeMessage(role: .server(serverConfiguration), previousSessionIdentifier: session)
                .keyExchangeAlgorithms,
            defaults
        )
        // And a rekey is never strict, even if the peer (wrongly) repeats its marker.
        var rekeyingServer = SSHKeyExchangeStateMachine(
            allocator: ByteBufferAllocator(),
            loop: EmbeddedEventLoop(),
            role: .server(serverConfiguration),
            remoteVersion: Constants.version,
            protectionSchemes: [AES256GCMOpenSSHTransportProtection.self],
            previousSessionIdentifier: session
        )
        rekeyingServer.send(keyExchange: rekeyingServer.createKeyExchangeMessage())
        XCTAssertNoThrow(try rekeyingServer.handle(keyExchange: clientFirst))
        XCTAssertFalse(rekeyingServer.isStrictKeyExchange)

        // A user-configured list gets it too; a marker the user wrote in by hand is not offered as an algorithm.
        clientConfiguration.keyExchangeAlgorithms = ["curve25519-sha256", "kex-strict-s-v00@openssh.com"]
        XCTAssertEqual(
            self.keyExchangeMessage(role: .client(clientConfiguration), previousSessionIdentifier: nil)
                .keyExchangeAlgorithms,
            ["curve25519-sha256", "kex-strict-c-v00@openssh.com"]
        )
    }

    func testMarkerDoesNotTriggerTheWrongGuessLogic() throws {
        // A peer that "guesses" with the same preferred algorithm and appends a marker is a correct guess.
        let clientRole = SSHConnectionRole.client(
            .init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())
        )
        var guess = self.keyExchangeMessage(role: clientRole, previousSessionIdentifier: nil)
        guess.firstKexPacketFollows = true
        var server = SSHKeyExchangeStateMachine(
            allocator: ByteBufferAllocator(),
            loop: EmbeddedEventLoop(),
            role: .server(.init(hostKeys: [.init(ed25519Key: .init())], userAuthDelegate: DenyAllServerAuthDelegate())),
            remoteVersion: Constants.version,
            protectionSchemes: [AES256GCMOpenSSHTransportProtection.self],
            previousSessionIdentifier: nil
        )
        let serverMessage = server.createKeyExchangeMessage()
        server.send(keyExchange: serverMessage)
        XCTAssertNil(try server.handle(keyExchange: guess))
        XCTAssertTrue(server.isStrictKeyExchange)
        // The guessed init is processed, not dropped.
        var client = SSHKeyExchangeStateMachine(
            allocator: ByteBufferAllocator(),
            loop: EmbeddedEventLoop(),
            role: clientRole,
            remoteVersion: Constants.version,
            protectionSchemes: [AES256GCMOpenSSHTransportProtection.self],
            previousSessionIdentifier: nil
        )
        client.send(keyExchange: guess)
        let initMessage = try client.handle(keyExchange: serverMessage)
        guard case .some(.keyExchangeInit(let message)) = initMessage?.first else {
            XCTFail("Expected a key exchange init")
            return
        }
        XCTAssertNotNil(try server.handle(keyExchangeInit: message))
    }

    // MARK: Sequence numbers

    func testBothStrictResetsSequenceNumbersWithEveryKeyExchange() throws {
        XCTAssertNoThrow(try self.configure(Options(protections: [KeyCheckingTransportProtection.self])))
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        XCTAssertNoThrow(try self.channel.clientSSHHandler!._rekey())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        XCTAssertNoThrow(try self.channel.serverSSHHandler!._rekey())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())

        // Two sides, three key exchanges: every set of keys starts counting at zero, both ways.
        let first = self.firstSequenceNumbers()
        XCTAssertEqual(first.count, 6)
        for (outbound, inbound) in first {
            XCTAssertEqual(outbound, 0)
            XCTAssertEqual(inbound, 0)
        }
    }

    func testOneSidedAnnouncementKeepsTodaysSequenceNumbers() throws {
        for (clientStrict, serverStrict) in [(false, true), (true, false)] {
            KeyCheckingTransportProtection.instances = []
            self.channel = BackToBackEmbeddedChannel()
            defer { try? self.channel.finish() }
            XCTAssertNoThrow(
                try self.configure(
                    Options(
                        clientStrict: clientStrict,
                        serverStrict: serverStrict,
                        protections: [KeyCheckingTransportProtection.self]
                    )
                )
            )
            XCTAssertNoThrow(try self.channel.interactInMemory())
            XCTAssertTrue(try self.openChannel())
            XCTAssertNoThrow(try self.channel.clientSSHHandler!._rekey())
            XCTAssertNoThrow(try self.channel.interactInMemory())
            XCTAssertTrue(try self.openChannel())

            // KEXINIT, KEX_ECDH_INIT / _REPLY and NEWKEYS went out in clear: the encrypted stream continues at 3,
            // and the rekey continues counting instead of starting over.
            let first = self.firstSequenceNumbers()
            XCTAssertEqual(first.count, 4)
            for (outbound, inbound) in first {
                XCTAssertGreaterThanOrEqual(outbound ?? 0, 3)
                XCTAssertGreaterThanOrEqual(inbound ?? 0, 3)
            }
        }
    }

    func testStrictKeyExchangeWithACustomKeyExchangeMethod() throws {
        NIOSSHAlgorithms.register(keyExchangeAlgorithm: ToyMPIntKeyExchange.self)
        let name = String(ToyMPIntKeyExchange.keyExchangeAlgorithmNames[0])
        XCTAssertNoThrow(
            try self.configure(Options(keyExchange: [name], protections: [KeyCheckingTransportProtection.self]))
        )
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        XCTAssertNoThrow(try self.channel.clientSSHHandler!._rekey())
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        let first = self.firstSequenceNumbers()
        XCTAssertEqual(first.count, 4)
        for (outbound, inbound) in first {
            XCTAssertEqual(outbound, 0)
            XCTAssertEqual(inbound, 0)
        }
    }

    // MARK: Unexpected messages during the initial key exchange

    private enum Injection {
        case beforeClientKeyExchangeInit
        case afterClientKeyExchangeInit
    }

    /// Runs the connection, slipping an SSH_MSG_IGNORE from "the client" into the server's inbound stream next to
    /// the client's KEXINIT. Returns the error that ended the connection, if any.
    private func runInjectingIgnore(_ injection: Injection) -> Error? {
        defer { self.drain() }
        var ignore = ByteBuffer()
        ignore.writeSSHPacket(
            message: .ignore(.init(data: ByteBuffer(string: "terrapin"))),
            lengthEncrypted: true,
            blockSize: 8
        )
        var injected = false
        do {
            var workToDo = true
            while workToDo {
                workToDo = false
                self.channel.run()
                if let clientData = try self.channel.client.readOutbound(as: IOData.self) {
                    guard case .byteBuffer(let buffer) = clientData else {
                        XCTFail("Unexpected IOData")
                        return nil
                    }
                    // A binary packet whose message type is SSH_MSG_KEXINIT (20).
                    let isKeyExchangeInit = !injected && buffer.getInteger(at: buffer.readerIndex + 5, as: UInt8.self) == 20
                    if isKeyExchangeInit, injection == .beforeClientKeyExchangeInit {
                        injected = true
                        try self.channel.server.writeInbound(IOData.byteBuffer(ignore))
                    }
                    try self.channel.server.writeInbound(clientData)
                    if isKeyExchangeInit, injection == .afterClientKeyExchangeInit {
                        injected = true
                        try self.channel.server.writeInbound(IOData.byteBuffer(ignore))
                    }
                    workToDo = true
                }
                if let serverData = try self.channel.server.readOutbound(as: IOData.self) {
                    try self.channel.client.writeInbound(serverData)
                    workToDo = true
                }
            }
        } catch {
            XCTAssertTrue(injected)
            return error
        }
        XCTAssertTrue(injected)
        return nil
    }

    /// Drops whatever is still queued after a connection was torn down, so that `finish()` sees clean channels.
    private func drain() {
        self.channel.run()
        while (try? self.channel.client.readOutbound(as: IOData.self)) != nil {}
        while (try? self.channel.server.readOutbound(as: IOData.self)) != nil {}
    }

    func testIgnoreDuringStrictInitialKeyExchangeKillsTheConnection() throws {
        XCTAssertNoThrow(try self.configure(Options()))
        let error = self.runInjectingIgnore(.afterClientKeyExchangeInit)
        XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        XCTAssertTrue(String(describing: error).contains("unexpected message during initial key exchange"), String(describing: error))
    }

    func testKeyExchangeInitThatIsNotTheFirstPacketKillsAStrictConnection() throws {
        XCTAssertNoThrow(try self.configure(Options()))
        let error = self.runInjectingIgnore(.beforeClientKeyExchangeInit)
        XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        XCTAssertTrue(String(describing: error).contains("KEXINIT was not the first packet"), String(describing: error))
    }

    func testIgnoreDuringNonStrictInitialKeyExchangeIsTolerated() throws {
        for injection in [Injection.beforeClientKeyExchangeInit, .afterClientKeyExchangeInit] {
            self.channel = BackToBackEmbeddedChannel()
            defer { try? self.channel.finish() }
            XCTAssertNoThrow(try self.configure(Options(clientStrict: false)))
            XCTAssertNil(self.runInjectingIgnore(injection))
            XCTAssertTrue(try self.openChannel())
        }
    }
}
