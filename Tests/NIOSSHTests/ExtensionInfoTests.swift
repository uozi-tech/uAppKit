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

/// Records the `server-sig-algs` it is handed, then authenticates with a password.
final class ServerSignatureAlgorithmsRecorder: NIOSSHClientUserAuthenticationDelegate {
    private(set) var calls: [[String]?] = []

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        XCTFail("NIOSSH must call the variant with serverSignatureAlgorithms")
        nextChallengePromise.succeed(nil)
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        serverSignatureAlgorithms: [String]?,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        self.calls.append(serverSignatureAlgorithms)
        nextChallengePromise.succeed(
            .init(username: "foo", serviceName: "", offer: .password(.init(password: "bar")))
        )
    }
}

/// Completes host key validation only when told to, so that the server's NEWKEYS and EXT_INFO arrive while the
/// client has not sent its own NEWKEYS yet.
final class ManualHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private(set) var pending: EventLoopPromise<Void>?

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        self.pending = validationCompletePromise
    }

    func complete() {
        self.pending?.succeed(())
        self.pending = nil
    }
}

final class ExtensionInfoTests: XCTestCase {
    private var channel: BackToBackEmbeddedChannel!
    private let announced = ["ssh-ed25519", "rsa-sha2-512", "rsa-sha2-256"]

    override func setUp() {
        super.setUp()
        self.channel = BackToBackEmbeddedChannel()
        KeyCheckingTransportProtection.instances = []
    }

    override func tearDown() {
        try? self.channel.finish()
        self.channel = nil
        KeyCheckingTransportProtection.instances = []
        super.tearDown()
    }

    private func configure(
        userAuth: NIOSSHClientUserAuthenticationDelegate,
        hostKeys: NIOSSHClientServerAuthenticationDelegate = AcceptAllHostKeysDelegate(),
        serverSignatureAlgorithms: [String]?,
        clientStrict: Bool = true,
        protections: [NIOSSHTransportProtection.Type] = Constants.bundledTransportProtectionSchemes
    ) throws {
        var client = SSHClientConfiguration(
            userAuthDelegate: userAuth,
            serverAuthDelegate: hostKeys,
            transportProtectionSchemes: protections
        )
        client.offersStrictKeyExchange = clientStrict
        var server = SSHServerConfiguration(
            hostKeys: [.init(ed25519Key: .init())],
            userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 0),
            transportProtectionSchemes: protections
        )
        server.serverSignatureAlgorithms = serverSignatureAlgorithms
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

    // MARK: Messages

    func testExtensionInfoRoundTripsAndParsesServerSigAlgs() throws {
        let message = SSHMessage.ExtensionInfoMessage(extensions: [
            .init(name: "server-sig-algs", value: ByteBuffer(string: "ssh-ed25519,rsa-sha2-512,rsa-sha2-256")),
            .init(name: "unknown@example.com", value: ByteBuffer(bytes: [0, 1, 2])),
        ])
        var buffer = ByteBuffer()
        _ = buffer.writeSSHMessage(.extensionInfo(message))
        XCTAssertEqual(buffer.getInteger(at: buffer.readerIndex, as: UInt8.self), 7)
        guard case .some(.extensionInfo(let parsed)) = try buffer.readSSHMessage() else {
            XCTFail("Expected SSH_MSG_EXT_INFO")
            return
        }
        XCTAssertEqual(parsed, message)
        XCTAssertEqual(parsed.serverSignatureAlgorithms, self.announced)
        XCTAssertEqual(buffer.readableBytes, 0)

        XCTAssertNil(SSHMessage.ExtensionInfoMessage(extensions: []).serverSignatureAlgorithms)
    }

    func testMalformedExtensionInfoIsRejectedWithoutTrustingItsCount() {
        // Claims 2^32-1 extensions in a handful of bytes.
        var huge = ByteBuffer()
        huge.writeInteger(UInt32.max)
        huge.writeSSHString("server-sig-algs".utf8)
        XCTAssertNil(huge.readExtensionInfoMessage())

        // Truncated value.
        var truncated = ByteBuffer()
        truncated.writeInteger(UInt32(1))
        truncated.writeSSHString("server-sig-algs".utf8)
        truncated.writeInteger(UInt32(100))
        XCTAssertNil(truncated.readExtensionInfoMessage())
        XCTAssertEqual(truncated.readerIndex, 0, "rewinds on failure")
    }

    // MARK: KEXINIT

    func testClientAnnouncesExtInfoInItsFirstKeyExchangeOnly() throws {
        let clientRole = SSHConnectionRole.client(
            .init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())
        )
        var serverConfiguration = SSHServerConfiguration(
            hostKeys: [.init(ed25519Key: .init())],
            userAuthDelegate: DenyAllServerAuthDelegate()
        )
        serverConfiguration.serverSignatureAlgorithms = self.announced
        func machine(_ role: SSHConnectionRole, _ previous: ByteBuffer?) -> SSHKeyExchangeStateMachine {
            SSHKeyExchangeStateMachine(
                allocator: ByteBufferAllocator(),
                loop: EmbeddedEventLoop(),
                role: role,
                remoteVersion: Constants.version,
                protectionSchemes: [AES256GCMOpenSSHTransportProtection.self],
                previousSessionIdentifier: previous
            )
        }
        let session = ByteBuffer(bytes: [1, 2, 3])

        let clientFirst = machine(clientRole, nil).createKeyExchangeMessage()
        XCTAssertTrue(clientFirst.keyExchangeAlgorithms.contains("ext-info-c"))
        XCTAssertFalse(machine(clientRole, session).createKeyExchangeMessage().keyExchangeAlgorithms.contains("ext-info-c"))
        // Servers never announce it (we do not want the client's EXT_INFO).
        let serverFirst = machine(.server(serverConfiguration), nil).createKeyExchangeMessage()
        XCTAssertFalse(serverFirst.keyExchangeAlgorithms.contains { $0.hasPrefix("ext-info") })

        // The server sends EXT_INFO only for a client that asked, in the first key exchange.
        var server = machine(.server(serverConfiguration), nil)
        server.send(keyExchange: serverFirst)
        XCTAssertNoThrow(try server.handle(keyExchange: clientFirst))
        XCTAssertEqual(server.extensionInfoToSend?.serverSignatureAlgorithms, self.announced)

        var oldClientMessage = clientFirst
        oldClientMessage.keyExchangeAlgorithms.removeAll { $0 == "ext-info-c" }
        var serverForOldClient = machine(.server(serverConfiguration), nil)
        serverForOldClient.send(keyExchange: serverFirst)
        XCTAssertNoThrow(try serverForOldClient.handle(keyExchange: oldClientMessage))
        XCTAssertNil(serverForOldClient.extensionInfoToSend)

        var rekeyingServer = machine(.server(serverConfiguration), session)
        rekeyingServer.send(keyExchange: rekeyingServer.createKeyExchangeMessage())
        XCTAssertNoThrow(try rekeyingServer.handle(keyExchange: clientFirst))
        XCTAssertNil(rekeyingServer.extensionInfoToSend)
    }

    // MARK: End to end

    func testClientDelegateSeesServerSigAlgs() throws {
        let recorder = ServerSignatureAlgorithmsRecorder()
        XCTAssertNoThrow(try self.configure(userAuth: recorder, serverSignatureAlgorithms: self.announced))
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        XCTAssertEqual(recorder.calls, [self.announced])
    }

    func testExtInfoWhileTheClientHasNotSentNewKeysYet() throws {
        let recorder = ServerSignatureAlgorithmsRecorder()
        let hostKeys = ManualHostKeyDelegate()
        XCTAssertNoThrow(
            try self.configure(userAuth: recorder, hostKeys: hostKeys, serverSignatureAlgorithms: self.announced)
        )
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertNotNil(hostKeys.pending)
        XCTAssertEqual(recorder.calls.count, 0)
        hostKeys.complete()
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        XCTAssertEqual(recorder.calls, [self.announced])
    }

    func testNoExtInfoMeansNil() throws {
        let recorder = ServerSignatureAlgorithmsRecorder()
        XCTAssertNoThrow(try self.configure(userAuth: recorder, serverSignatureAlgorithms: nil))
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
        XCTAssertEqual(recorder.calls, [nil])
    }

    func testDelegatesWithoutTheNewRequirementStillWork() throws {
        XCTAssertNoThrow(
            try self.configure(userAuth: InfinitePasswordDelegate(), serverSignatureAlgorithms: self.announced)
        )
        XCTAssertNoThrow(try self.channel.interactInMemory())
        XCTAssertTrue(try self.openChannel())
    }

    /// Under strict key exchange EXT_INFO is the first packet under the new keys, so it goes out (and is checked)
    /// with sequence number 0; without strict key exchange it simply continues the count.
    func testExtInfoUnderStrictKeyExchange() throws {
        for clientStrict in [true, false] {
            KeyCheckingTransportProtection.instances = []
            self.channel = BackToBackEmbeddedChannel()
            defer { try? self.channel.finish() }
            let recorder = ServerSignatureAlgorithmsRecorder()
            XCTAssertNoThrow(
                try self.configure(
                    userAuth: recorder,
                    serverSignatureAlgorithms: self.announced,
                    clientStrict: clientStrict,
                    protections: [KeyCheckingTransportProtection.self]
                )
            )
            XCTAssertNoThrow(try self.channel.interactInMemory())
            XCTAssertTrue(try self.openChannel())
            XCTAssertEqual(recorder.calls, [self.announced])
            for instance in KeyCheckingTransportProtection.instances {
                guard case .some(.outbound(let first)) = instance.events.first(where: {
                    if case .outbound = $0 { return true } else { return false }
                }) else {
                    XCTFail("No outbound packet")
                    continue
                }
                if clientStrict {
                    XCTAssertEqual(first, 0)
                } else {
                    XCTAssertGreaterThanOrEqual(first, 3)
                }
            }
        }
    }
}
