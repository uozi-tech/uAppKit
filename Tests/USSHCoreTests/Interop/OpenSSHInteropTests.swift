import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
@testable import USSHCore
import XCTest

/// 对本机真实 OpenSSH 的互通测试。sshd 起不来时整组跳过（见 `OpenSSHFixture`）。
final class OpenSSHInteropTests: XCTestCase {
    private var fixture: OpenSSHFixture!

    override func setUp() async throws {
        fixture = try await OpenSSHFixture.start()
    }

    override func tearDown() async throws {
        fixture?.stop()
        fixture = nil
    }

    private func collect(_ output: SSHChannelOutput) async throws -> (stdout: String, stderr: String) {
        var stdout = "", stderr = ""
        for try await chunk in output {
            switch chunk {
            case .stdout(let buffer): stdout += String(buffer: buffer)
            case .stderr(let buffer): stderr += String(buffer: buffer)
            }
        }
        return (stdout, stderr)
    }

    // MARK: - 认证

    func testEd25519KeyAuthenticationAndExec() async throws {
        let client = try await fixture.connect(fixture.ed25519Key)
        defer { Task { await client.close() } }
        let handle = try await client.openExec("echo out; echo err 1>&2; exit 3")
        let (stdout, stderr) = try await collect(handle.output)
        XCTAssertEqual(stdout, "out\n")
        XCTAssertEqual(stderr, "err\n")
        let status = await handle.exitStatus()
        XCTAssertEqual(status, .exited(3))

        let whoami = try await client.executeCommand("whoami")
        XCTAssertEqual(String(buffer: whoami), fixture.username + "\n")
    }

    func testECDSAKeyAuthentication() async throws {
        for key in [fixture.p256Key, fixture.p384Key] {
            let client = try await fixture.connect(key)
            let output = try await client.executeCommand("echo ok")
            XCTAssertEqual(String(buffer: output), "ok\n")
            await client.close()
        }
    }

    func testWrongKeyIsRejected() async throws {
        let stranger = NIOSSHPrivateKey(ed25519Key: .init())
        await XCTAssertThrowsAsync(try await fixture.connect(stranger)) { error in
            guard case SSHClientError.authenticationFailed(let failure) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(failure.attemptedMethods, [.publicKey])
            XCTAssertTrue(failure.remainingMethods.contains(.publicKey))
        }
    }

    func testWrongHostKeyIsRejected() async throws {
        var configuration = fixture.configuration()
        configuration.hostKeyValidation = .trustedKeys([NIOSSHPrivateKey(ed25519Key: .init()).publicKey])
        await XCTAssertThrowsAsync(try await SSHClient.connect(
            host: "127.0.0.1", port: fixture.port, configuration: configuration)) { error in
            guard case SSHClientError.hostKeyRejected = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: - exec

    func testExitCodesAndNonZeroExitError() async throws {
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        await XCTAssertThrowsAsync(try await client.executeCommand("printf partial; exit 42")) { error in
            guard case SSHCommandError.nonZeroExit(let status, let output) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(status, .exited(42))
            XCTAssertEqual(String(buffer: output), "partial")
        }
        let killed = try await client.openExec("kill -KILL $$")
        _ = try await collect(killed.output)
        let status = await killed.exitStatus()
        XCTAssertEqual(status, .signaled(SSHExitSignal(name: "KILL", coreDumped: false, message: "")))
    }

    func testStdinAndEOF() async throws {
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        let (text, status) = try await client.withExec("cat") { output, handle in
            var payload = ByteBuffer()
            payload.writeRepeatingByte(0x7a, count: 300_000)
            try await handle.write(payload)
            try await handle.write(ByteBuffer(string: "END"))
            try await handle.sendEOF()
            var received = 0
            var tail = ""
            for try await chunk in output {
                received += chunk.buffer.readableBytes
                tail = String(String(buffer: chunk.buffer).suffix(3))
            }
            return ("\(received):\(tail)", await handle.exitStatus())
        }
        XCTAssertEqual(text, "300003:END")
        XCTAssertEqual(status, .exited(0))
    }

    func testEnvironment() async throws {
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        // USSH_* 在 AcceptEnv 里；NOT_ACCEPTED 会被 sshd 默默忽略，不影响命令。
        let output = try await client.executeCommand(
            "echo \"$USSH_VALUE|${NOT_ACCEPTED:-unset}\"",
            environment: ["USSH_VALUE": "hello world", "NOT_ACCEPTED": "x"])
        XCTAssertEqual(String(buffer: output), "hello world|unset\n")
    }

    // MARK: - PTY

    func testExecWithPTY() async throws {
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        let handle = try await client.openExec(
            "tty; stty size; echo TERM=$TERM",
            pty: SSHPseudoTerminal(term: "vt220", columns: 101, rows: 33))
        let (stdout, _) = try await collect(handle.output)
        XCTAssertTrue(stdout.contains("/dev/"), stdout)
        XCTAssertTrue(stdout.contains("33 101"), stdout)
        XCTAssertTrue(stdout.contains("TERM=vt220"), stdout)
    }

    func testInteractiveShellResize() async throws {
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        let shell = try await client.openShell(
            pty: SSHPseudoTerminal(columns: 80, rows: 24), environment: ["LANG": "en_US.UTF-8"])
        let screen = NIOLockedValueBox("")
        let reader = Task {
            for try await chunk in shell.output {
                screen.withLockedValue { $0 += String(buffer: chunk.buffer) }
            }
        }
        try await shell.write(ByteBuffer(string: "stty size; echo MARK-A\n"))
        let first = await Harness.eventually(timeout: .seconds(10)) {
            screen.withLockedValue { $0.contains("24 80") && $0.contains("MARK-A\r\n") }
        }
        XCTAssertTrue(first, screen.withLockedValue { $0 })
        try await shell.resize(columns: 132, rows: 43)
        try await shell.write(ByteBuffer(string: "stty size; echo MARK-B\n"))
        let second = await Harness.eventually(timeout: .seconds(10)) {
            screen.withLockedValue { $0.contains("43 132") && $0.contains("MARK-B\r\n") }
        }
        XCTAssertTrue(second, screen.withLockedValue { $0 })
        try await shell.write(ByteBuffer(string: "exit 5\n"))
        _ = try await reader.value
        let status = await shell.exitStatus()
        XCTAssertEqual(status, .exited(5))
    }

    // MARK: - 取消

    func testCancellationTerminatesRemoteCommand() async throws {
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        let marker = "1000.\(Int.random(in: 100_000...999_999))"
        let task = Task { try await client.executeCommand("sleep \(marker)") }
        let started = await Harness.eventually(timeout: .seconds(5)) {
            (try? await client.executeCommand("pgrep -f 'sleep \(marker)' || true"))
                .map { String(buffer: $0).isEmpty == false } ?? false
        }
        XCTAssertTrue(started)
        task.cancel()
        _ = await task.result
        let gone = await Harness.eventually(timeout: .seconds(5)) {
            (try? await client.executeCommand("pgrep -f 'sleep \(marker)' || true"))
                .map { String(buffer: $0).isEmpty } ?? false
        }
        XCTAssertTrue(gone, "remote process still running after cancellation")
    }

    func testCancellingPTYConsumerHangsUpTheShell() async throws {
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        let marker = "1001.\(Int.random(in: 100_000...999_999))"
        let shell = try await client.openShell(pty: SSHPseudoTerminal())
        let reader = Task { for try await _ in shell.output {} }
        try await shell.write(ByteBuffer(string: "sleep \(marker)\n"))
        let started = await Harness.eventually(timeout: .seconds(5)) {
            (try? await client.executeCommand("pgrep -f 'sleep \(marker)' || true"))
                .map { String(buffer: $0).isEmpty == false } ?? false
        }
        XCTAssertTrue(started)
        reader.cancel()
        _ = await reader.result
        let gone = await Harness.eventually(timeout: .seconds(5)) {
            (try? await client.executeCommand("pgrep -f 'sleep \(marker)' || true"))
                .map { String(buffer: $0).isEmpty } ?? false
        }
        XCTAssertTrue(gone, "PTY process still running after the channel closed")
    }

    // MARK: - 转发与跳板机

    func testDirectTCPIPToLocalEchoServer() async throws {
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        let channel = try await client.openDirectTCPIPAsyncChannel(
            targetHost: "127.0.0.1", targetPort: echo.port,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
        let text = try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(string: "via sshd"))
            outbound.finish()
            var text = ""
            for try await buffer in inbound { text += String(buffer: buffer) }
            return text
        }
        XCTAssertEqual(text, "via sshd")
    }

    func testRemotePortForward() async throws {
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        let forward = try await client.startRemotePortForward(host: "127.0.0.1", port: 0) { channel, _ in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(ByteEchoHandler())
            }
        }
        XCTAssertGreaterThan(forward.boundPort, 0)
        let reply = try await SSHForwardingChannelTests.roundTrip(port: forward.boundPort, message: "-R via sshd")
        XCTAssertEqual(reply, "-R via sshd")
        await forward.cancel()
    }

    func testJumpThroughSSHD() async throws {
        let outer = try await fixture.connect()
        let inner = try await outer.jump(to: "127.0.0.1", port: fixture.port, configuration: fixture.configuration())
        let output = try await inner.executeCommand("echo inner")
        XCTAssertEqual(String(buffer: output), "inner\n")
        await outer.close()
        let reason = await inner.waitForDisconnect()
        XCTAssertFalse(reason.isLocalClose)
    }

    // MARK: - 保活与开通道失败的原因码

    func testPingAndKeepAliveAgainstSSHD() async throws {
        var configuration = fixture.configuration()
        configuration.keepAliveInterval = .milliseconds(150)
        configuration.keepAliveMaximumUnanswered = 2
        let client = try await SSHClient.connect(host: "127.0.0.1", port: fixture.port, configuration: configuration)
        defer { Task { await client.close() } }
        for _ in 0..<3 { try await client.ping(timeout: .seconds(5)) }
        // 好几个保活周期之后连接仍在（sshd 对 keepalive@openssh.com 回 FAILURE，也算回应）。
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertTrue(client.isConnected)
        let output = try await client.executeCommand("echo alive")
        XCTAssertEqual(String(buffer: output), "alive\n")
    }

    func testForwardingProhibitedReasonCode() async throws {
        let restricted = try await OpenSSHFixture.start(extraConfig: "PermitOpen 127.0.0.1:9")
        defer { restricted.stop() }
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }
        let client = try await restricted.connect()
        defer { Task { await client.close() } }
        await XCTAssertThrowsAsync(try await client.openDirectTCPIPAsyncChannel(
            targetHost: "127.0.0.1", targetPort: echo.port,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))) { error in
            guard case SSHChannelError.openRejected(let failure) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(failure.reason, .administrativelyProhibited, "\(failure)")
        }
        // 允许的目标但没人监听：连接失败。
        await XCTAssertThrowsAsync(try await client.openDirectTCPIPAsyncChannel(
            targetHost: "127.0.0.1", targetPort: 9,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))) { error in
            guard case SSHChannelError.openRejected(let failure) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(failure.reason, .connectFailed, "\(failure)")
        }
        XCTAssertTrue(client.isConnected)
    }

    // MARK: - 断开

    func testDisconnectNotificationWhenSSHDIsKilled() async throws {
        let client = try await fixture.connect()
        let observed = NIOLockedValueBox<SSHDisconnectReason?>(nil)
        client.onDisconnect { reason in observed.withLockedValue { $0 = reason } }
        _ = try await client.executeCommand("true")
        fixture.kill()
        let reason = await client.waitForDisconnect()
        XCTAssertFalse(reason.isLocalClose)
        XCTAssertNotNil(observed.withLockedValue { $0 })
        XCTAssertFalse(client.isConnected)
    }

    // MARK: - subsystem

    func testSFTPSubsystemChannelContract() async throws {
        let client = try await fixture.connect()
        defer { Task { await client.close() } }
        let channel = try await client.openSubsystemChannel("sftp")
        let asyncChannel = try await channel.eventLoop.submit {
            try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
        }.get()
        let (type, version) = try await asyncChannel.executeThenClose { inbound, outbound in
            // SSH_FXP_INIT：uint32 长度 5，byte 1，uint32 版本 3。
            var initPacket = ByteBuffer()
            initPacket.writeInteger(UInt32(5))
            initPacket.writeInteger(UInt8(1))
            initPacket.writeInteger(UInt32(3))
            try await outbound.write(initPacket)
            var received = ByteBuffer()
            for try await var buffer in inbound {
                received.writeBuffer(&buffer)
                if let length = received.getInteger(at: received.readerIndex, as: UInt32.self),
                   received.readableBytes >= 4 + Int(length) {
                    break
                }
            }
            _ = received.readInteger(as: UInt32.self)
            return (received.readInteger(as: UInt8.self), received.readInteger(as: UInt32.self))
        }
        XCTAssertEqual(type, 2)   // SSH_FXP_VERSION
        XCTAssertEqual(version, 3)
    }
}
