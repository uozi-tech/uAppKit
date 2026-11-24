import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOSSH
@testable import USSHCore
import USSHTestServer
import XCTest

final class SSHSessionChannelTests: XCTestCase {
    private func start(_ exec: SSHTestExecHandler,
                       configure: (inout SSHTestServer.Configuration) -> Void = { _ in }) async throws -> (SSHTestServer, SSHClient) {
        var configuration = Harness.serverConfiguration(exec: exec)
        configure(&configuration)
        let server = try await SSHTestServer.start(configuration)
        let client = try await Harness.connect(server)
        return (server, client)
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

    // MARK: - exec

    func testExecStdoutStderrAndExitStatus() async throws {
        let (server, client) = try await start(.scripted(stdout: "out\n", stderr: "err\n", exitStatus: 7))
        defer { Task { await client.close(); await server.stop() } }
        let handle = try await client.openExec("do-it")
        let (stdout, stderr) = try await collect(handle.output)
        XCTAssertEqual(stdout, "out\n")
        XCTAssertEqual(stderr, "err\n")
        let status = await handle.exitStatus()
        XCTAssertEqual(status, .exited(7))
        XCTAssertFalse(handle.isActive)
        XCTAssertEqual(server.events.execCommands, ["do-it"])
    }

    func testExitSignalIsReported() async throws {
        let (server, client) = try await start(SSHTestExecHandler { _ in .signal("KILL") })
        defer { Task { await client.close(); await server.stop() } }
        let handle = try await client.openExec("x")
        _ = try await collect(handle.output)
        let status = await handle.exitStatus()
        XCTAssertEqual(status, .signaled(SSHExitSignal(name: "KILL", coreDumped: false, message: "")))
    }

    /// 远端报了退出状态、但通道还开着（后台进程占着伪终端）：`exitStatusReported()` 不等通道关就返回，
    /// 之后的输出照样读得到；`exitStatus()` 那条路不受影响。
    func testExitStatusReportedBeforeTheChannelCloses() async throws {
        let (server, client) = try await start(SSHTestExecHandler { context in
            try await context.write("bye\n")
            context.channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
            try await Task.sleep(for: .milliseconds(200))
            try await context.write("late\n")           // 后台进程还在写
            for await _ in context.stdin {}             // 一直占着，直到客户端关通道
            return .noStatus
        })
        defer { Task { await client.close(); await server.stop() } }
        let shell = try await client.openExec("sleep 1000 & exit")
        let reported = await withTaskGroup(of: SSHExitStatus??.self) { group in
            group.addTask { await shell.exitStatusReported() }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return .some(nil) }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        XCTAssertEqual(reported, .some(.exited(0)), "退出状态一到就返回，不等通道关")
        XCTAssertTrue(shell.isActive, "通道还开着")
        var collected = ""
        for try await chunk in shell.output {
            collected += String(buffer: chunk.buffer)
            if collected.contains("late") { break }
        }
        XCTAssertTrue(collected.contains("bye") && collected.contains("late"), collected)
        await shell.close()
    }

    /// 通道关了也没等到退出状态：返回 nil，不挂住。
    func testExitStatusReportedReturnsNilWhenTheChannelClosesWithoutOne() async throws {
        let (server, client) = try await start(SSHTestExecHandler { _ in .noStatus })
        defer { Task { await client.close(); await server.stop() } }
        let handle = try await client.openExec("x")
        _ = try await collect(handle.output)
        let reported = await handle.exitStatusReported()
        XCTAssertNil(reported)
    }

    func testExecuteCommandConveniences() async throws {
        let (server, client) = try await start(.routes([
            "ok": .scripted(stdout: "fine", stderr: "noise"),
            "fail": .scripted(stdout: "partial", exitStatus: 3),
            "big": .scripted(stdout: String(repeating: "x", count: 100)),
            "both": .scripted(stdout: "a", stderr: "b"),
        ]))
        defer { Task { await client.close(); await server.stop() } }

        let ok = try await client.executeCommand("ok")
        XCTAssertEqual(Harness.string(ok), "fine")
        let both = try await client.executeCommand("both", mergeStreams: true)
        XCTAssertEqual(Harness.string(both), "ab")

        await XCTAssertThrowsAsync(try await client.executeCommand("fail")) { error in
            guard case SSHCommandError.nonZeroExit(let status, let output) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(status, .exited(3))
            XCTAssertEqual(String(buffer: output), "partial")
        }
        await XCTAssertThrowsAsync(try await client.executeCommand("big", maxResponseSize: 10)) { error in
            guard case SSHCommandError.outputTooLarge(let limit) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(limit, 10)
        }
        await XCTAssertThrowsAsync(try await client.executeCommand("missing")) { error in
            guard case SSHCommandError.nonZeroExit(.exited(127), _) = error else { return XCTFail("unexpected \(error)") }
        }
        // 同一条连接还能接着用。
        let again = try await client.executeCommand("ok")
        XCTAssertEqual(Harness.string(again), "fine")
    }

    func testExecuteCommandStreamThrowsAtEndOnNonZeroExit() async throws {
        let (server, client) = try await start(.routes([
            "ok": .scripted(stdout: "one"),
            "fail": .scripted(stdout: "two", exitStatus: 2),
        ]))
        defer { Task { await client.close(); await server.stop() } }

        var received = ""
        for try await chunk in try await client.executeCommandStream("ok") {
            received += String(buffer: chunk.buffer)
        }
        XCTAssertEqual(received, "one")

        received = ""
        do {
            for try await chunk in try await client.executeCommandStream("fail") {
                received += String(buffer: chunk.buffer)
            }
            XCTFail("expected an error")
        } catch SSHCommandError.nonZeroExit(let status, _) {
            XCTAssertEqual(status, .exited(2))
        }
        XCTAssertEqual(received, "two")
    }

    func testStdinAndEOF() async throws {
        let (server, client) = try await start(.echo)
        defer { Task { await client.close(); await server.stop() } }
        let status = try await client.withExec("cat") { output, handle in
            try await handle.write(Array("hello ".utf8))
            try await handle.write(ByteBuffer(string: "world"))
            try await handle.sendEOF()
            var echoed = ""
            for try await chunk in output { echoed += String(buffer: chunk.buffer) }
            XCTAssertEqual(echoed, "hello world")
            return await handle.exitStatus()
        }
        XCTAssertEqual(status, .exited(0))
        // EOF 之后不能再写。
        let handle = try await client.openExec("cat")
        try await handle.sendEOF()
        await XCTAssertThrowsAsync(try await handle.write(ByteBuffer(string: "late"))) { error in
            guard case SSHChannelError.channelClosed = error else { return XCTFail("unexpected \(error)") }
        }
        await handle.close()
    }

    func testEOFAfterPeerEOF() async throws {
        // 远端先关 stdout，再读完我们的 stdin；我们后发 EOF（RFC 4254 §5.3 允许任意次序，NIOSSH 补丁 0004）。
        let (server, client) = try await start(SSHTestExecHandler { context in
            await context.sendEOF()
            var count = 0
            for await chunk in context.stdin { count += chunk.readableBytes }
            return .status(count == 5 ? 0 : 1)
        })
        defer { Task { await client.close(); await server.stop() } }
        let handle = try await client.openExec("read-after-eof")
        try await Task.sleep(for: .milliseconds(200))
        try await handle.write(ByteBuffer(string: "12345"))
        try await handle.sendEOF()
        let status = await handle.exitStatus()
        XCTAssertEqual(status, .exited(0))
    }

    func testEnvironmentRejectionIsNotFatal() async throws {
        let (server, client) = try await start(SSHTestExecHandler { context in
            try await context.write(context.environment.keys.sorted().joined(separator: ","))
            return .status(0)
        }, configure: { $0.acceptedEnvironmentNames = ["LANG"] })
        defer { Task { await client.close(); await server.stop() } }
        let output = try await client.executeCommand("env", environment: ["LANG": "en_US.UTF-8", "FOO": "bar"])
        XCTAssertEqual(String(buffer: output), "LANG")
        XCTAssertEqual(server.events.environment, ["LANG": "en_US.UTF-8"])
        XCTAssertEqual(server.events.rejectedEnvironment, ["FOO"])
    }

    func testExecWithPseudoTerminal() async throws {
        let (server, client) = try await start(SSHTestExecHandler { context in
            try await context.write(context.pty?.term ?? "none")
            return .status(0)
        })
        defer { Task { await client.close(); await server.stop() } }
        let handle = try await client.openExec("tty", pty: SSHPseudoTerminal(term: "vt100", columns: 90, rows: 20))
        let (stdout, _) = try await collect(handle.output)
        XCTAssertEqual(stdout, "vt100")
        XCTAssertEqual(server.events.ptyRequests.map(\.columns), [90])
    }

    // MARK: - shell / PTY

    func testShellWithPTYRecordsRequestsAndEchoes() async throws {
        let (server, client) = try await start(.notFound)
        defer { Task { await client.close(); await server.stop() } }
        let pty = SSHPseudoTerminal(term: "xterm-test", columns: 100, rows: 30, pixelWidth: 800, pixelHeight: 600)
        let shell = try await client.openShell(pty: pty, environment: ["LANG": "C.UTF-8"])
        var iterator = shell.output.makeAsyncIterator()

        try await shell.write(ByteBuffer(string: "hi"))
        let echoed = try await iterator.next()
        XCTAssertEqual(echoed.map { String(buffer: $0.buffer) }, "hi")

        try await shell.resize(columns: 120, rows: 40)
        try await server.waitForEvents { !$0.windowChanges.isEmpty }

        try await shell.write([0x04])
        while try await iterator.next() != nil {}
        let status = await shell.exitStatus()
        XCTAssertEqual(status, .exited(0))

        let events = server.events
        XCTAssertEqual(events.shellRequests, 1)
        XCTAssertEqual(events.ptyRequests, [SSHTestPTYInfo(
            term: "xterm-test", columns: 100, rows: 30, pixelWidth: 800, pixelHeight: 600, modes: SSHTerminalModes([:]))])
        XCTAssertEqual(events.windowChanges, [SSHTestWindowSize(columns: 120, rows: 40, pixelWidth: 0, pixelHeight: 0)])
        XCTAssertEqual(events.environment, ["LANG": "C.UTF-8"])
    }

    func testWithPTYClosesChannelWhenBodyReturns() async throws {
        let (server, client) = try await start(.notFound)
        defer { Task { await client.close(); await server.stop() } }
        let channel = try await client.withPTY(SSHPseudoTerminal(columns: 80, rows: 24)) { output, shell in
            try await shell.write(ByteBuffer(string: "x"))
            var iterator = output.makeAsyncIterator()
            _ = try await iterator.next()
            return shell.channel
        }
        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(server.events.ptyRequests.first?.term, "xterm-256color")
    }

    func testRejectedPTYRequestFailsOpen() async throws {
        let server = try await SSHTestServer.start(Harness.serverConfiguration())
        defer { Task { await server.stop() } }
        let client = try await Harness.connect(server)
        defer { Task { await client.close() } }
        // 同一通道上第二个 exec 会被测试服务端拒绝；这里改用不存在的 subsystem 测 requestRejected。
        await XCTAssertThrowsAsync(try await client.openSubsystemChannel("nope")) { error in
            guard case SSHChannelError.requestRejected(.subsystem("nope")) = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(client.isConnected)
    }

    // MARK: - 取消、背压、断开

    func testCancellingTheConsumerClosesTheChannel() async throws {
        let ended = Counter()
        let (server, client) = try await start(SSHTestExecHandler { context in
            defer { ended.add(1) }
            while true {
                try await context.write("tick\n")
                try await Task.sleep(for: .milliseconds(5))
            }
        })
        defer { Task { await client.close(); await server.stop() } }
        let handle = try await client.openExec("forever")
        let firstChunk = NIOLockedValueBox(false)
        let consumer = Task {
            for try await _ in handle.output {
                firstChunk.withLockedValue { $0 = true }
            }
        }
        let gotData = await Harness.eventually { firstChunk.withLockedValue { $0 } }
        XCTAssertTrue(gotData)
        consumer.cancel()
        _ = await consumer.result
        let closed = await Harness.eventually { !handle.isActive && ended.value == 1 }
        XCTAssertTrue(closed)
        XCTAssertTrue(client.isConnected)
    }

    func testCancellingExecuteCommandClosesTheChannel() async throws {
        let ended = Counter()
        let (server, client) = try await start(SSHTestExecHandler { context in
            defer { ended.add(1) }
            try await Task.sleep(for: .seconds(60))
            return .status(0)
        })
        defer { Task { await client.close(); await server.stop() } }
        let task = Task { try await client.executeCommand("sleep 60") }
        try await server.waitForEvents { !$0.execCommands.isEmpty }
        task.cancel()
        await XCTAssertThrowsAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError, "unexpected \(error)")
        }
        let stopped = await Harness.eventually { ended.value == 1 }
        XCTAssertTrue(stopped)
        // 取消时先发了 signal TERM。
        XCTAssertEqual(server.events.signals, ["TERM"])
    }

    func testBackpressureBoundsBufferedBytes() async throws {
        let chunkSize = 64 * 1024
        let chunkCount = 512   // 32 MiB
        let written = Counter()
        var chunk = ByteBuffer()
        chunk.writeRepeatingByte(0x61, count: chunkSize)
        let payload = chunk
        let (server, client) = try await start(SSHTestExecHandler { context in
            for _ in 0..<chunkCount {
                try await context.write(payload)
                written.add(payload.readableBytes)
            }
            return .status(0)
        })
        defer { Task { await client.close(); await server.stop() } }

        let handle = try await client.openExec("produce")
        // 不读：对端最多写满我们的窗口（包长 × 64 = 8 MiB），再加几块在途。
        try await Task.sleep(for: .milliseconds(800))
        let window = Harness.clientConfiguration().channelWindowSize
        let stalled = written.value
        XCTAssertLessThanOrEqual(stalled, window + 4 * chunkSize, "server wrote \(stalled) bytes into a paused reader")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(written.value, stalled, "producer kept going while the consumer was paused")

        var total = 0
        for try await piece in handle.output { total += piece.buffer.readableBytes }
        XCTAssertEqual(total, chunkSize * chunkCount)
        let status = await handle.exitStatus()
        XCTAssertEqual(status, .exited(0))
    }

    func testConnectionDropFailsTheOutputSequence() async throws {
        let (server, client) = try await start(SSHTestExecHandler { context in
            while true {
                try await context.write("tick\n")
                try await Task.sleep(for: .milliseconds(5))
            }
        })
        defer { Task { await server.stop() } }
        let handle = try await client.openExec("forever")
        var iterator = handle.output.makeAsyncIterator()
        _ = try await iterator.next()
        await server.dropAllConnections()
        do {
            while try await iterator.next() != nil {}
            XCTFail("expected the sequence to fail")
        } catch SSHChannelError.connectionClosed(let reason) {
            // 服务端直接关 TCP（没有错误）：对端正常关闭，不是传输错误。
            guard case .remoteClosed = reason else { return XCTFail("unexpected \(reason)") }
        }
        let reason = await client.waitForDisconnect()
        guard case .remoteClosed = reason else { return XCTFail("unexpected \(reason)") }
    }

    func testServerClosingChannelWhileClientHasBufferedData() async throws {
        let size = 4 * 1024 * 1024
        let (server, client) = try await start(SSHTestExecHandler { context in
            var buffer = ByteBuffer()
            buffer.writeRepeatingByte(0x62, count: 256 * 1024)
            for _ in 0..<(size / buffer.readableBytes) {
                try await context.write(buffer)
            }
            await context.closeChannel()
            return .noStatus
        })
        defer { Task { await client.close(); await server.stop() } }
        let handle = try await client.openExec("dump-and-close")
        // 先不读，让数据堆在本端，对端在这期间发 CHANNEL_CLOSE。
        try await Task.sleep(for: .milliseconds(500))
        var total = 0
        for try await piece in handle.output { total += piece.buffer.readableBytes }
        XCTAssertEqual(total, size)
        let status = await handle.exitStatus()
        XCTAssertEqual(status, .unknown)
        XCTAssertTrue(client.isConnected)
    }

    func testManyConcurrentChannelsOnOneConnection() async throws {
        let (server, client) = try await start(SSHTestExecHandler { context in
            try await Task.sleep(for: .milliseconds(20))
            try await context.write("echo:\(context.command)")
            return .status(0)
        })
        defer { Task { await client.close(); await server.stop() } }
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<24 {
                group.addTask { (index, String(buffer: try await client.executeCommand("\(index)"))) }
            }
            var results: [Int: String] = [:]
            for try await (index, output) in group { results[index] = output }
            return results
        }
        XCTAssertEqual(results.count, 24)
        for (index, output) in results { XCTAssertEqual(output, "echo:\(index)") }
    }

    func testTerminateSendsSignal() async throws {
        let (server, client) = try await start(SSHTestExecHandler { _ in
            try await Task.sleep(for: .seconds(60))
            return .status(0)
        })
        defer { Task { await client.close(); await server.stop() } }
        let handle = try await client.openExec("sleep 60")
        await handle.terminate()
        XCTAssertFalse(handle.isActive)
        try await server.waitForEvents { $0.signals == ["TERM"] }
    }

    func testReleasingTheHandleClosesTheChannel() async throws {
        let ended = Counter()
        let (server, client) = try await start(SSHTestExecHandler { context in
            defer { ended.add(1) }
            try await Task.sleep(for: .seconds(60))
            return .status(0)
        })
        defer { Task { await client.close(); await server.stop() } }
        let channel = try await { () async throws -> any Channel in
            let handle = try await client.openExec("sleep 60")
            return handle.channel
        }()
        let closed = await Harness.eventually { !channel.isActive && ended.value == 1 }
        XCTAssertTrue(closed)
    }
}

/// 请求 handler 没能加进 pipeline（通道已经拆了）时，它手里的 exit-status promise 也要完成，不能漏
/// （NIO 在 Debug 下发现漏完成的 promise 会直接让进程崩掉）。
final class SSHChannelRequestHandlerLifecycleTests: XCTestCase {
    func testPromiseIsCompletedWhenTheHandlerIsNeverAdded() throws {
        let channel = EmbeddedChannel()
        _ = try channel.finish(acceptAlreadyClosed: true)
        var future: EventLoopFuture<SSHExitStatus?>?
        do {
            let handler = SSHChannelRequestHandler(eventLoop: channel.eventLoop)
            future = handler.exitStatusArrival.futureResult
            XCTAssertThrowsError(try channel.pipeline.syncOperations.addHandler(handler), "通道已经关了，加不进去")
        }
        // handler 已经释放；promise 在它的 deinit 里完成成 nil。
        XCTAssertEqual(try future?.wait(), .some(nil))
    }
}
