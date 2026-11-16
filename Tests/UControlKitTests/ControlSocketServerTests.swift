#if os(macOS)

import Darwin
import Foundation
import XCTest
@testable import UControlKit

/// 真起一个 `ControlSocketServer`，用裸 Unix socket 打它。移植自 uTerm 的
/// `uTermTests/Core/Control/ControlServerTests.swift`（它又移植自 uTable 的同名用例），
/// 保留纯服务端的不变式：并发上限、两级准入、I/O 超时、按静默而非总时长的 handler 监督、
/// 心跳、进度行、fd 传递、handler 超时后晚到的响应不双关同一个 fd、stop 时 unlink、
/// 不抢别人的 socket、路径超长不 bind。
///
/// handler 跑在 MainActor 上（与 app 里 `ControlDispatcher` 一样），所以所有阻塞的 socket
/// 调用都要丢到全局队列：主线程若被同步 recv 堵着，handler 永远排不上号，只会等到超时。
@MainActor
final class ControlSocketServerTests: XCTestCase {
    /// `swift test` 不沙盒，临时目录是 `/var/folders/…/T/`，加上文件名仍在 `sun_path` 以内；
    /// setUp 里量一次，超了就跳过而不是红一片。
    private var socketURL: URL!
    private var server: TestServer?

    override func setUp() async throws {
        try await super.setUp()
        socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "uc-\(UUID().uuidString.prefix(8)).sock")
            .standardizedFileURL
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: socketURL)
        try await super.tearDown()
    }

    /// 起服务端并等 socket 真正出现（accept 循环在自己的队列上异步铺开）。
    private func startServer(
        maxActiveClients: Int = 8,
        maxLongLivedClients: Int = 4,
        ioTimeout: TimeInterval = 5,
        handlerIdleTimeout: TimeInterval = 10,
        heartbeatInterval: TimeInterval = 10,
        _ handler: @escaping @MainActor @Sendable (TestRequest) async -> TestResponse
    ) async throws {
        try XCTSkipUnless(
            ControlSocketLocation.fitsInSunPath(socketURL),
            "临时目录太长，装不下 socket 路径：\(socketURL.path)"
        )
        let server = TestServer(
            socketURL: socketURL,
            appName: "uTest",
            limits: .init(
                maxActiveClients: maxActiveClients,
                maxLongLivedClients: maxLongLivedClients,
                ioTimeout: ioTimeout,
                // 出问题时秒级失败，而不是让每条用例各等两分钟的生产默认值。
                handlerIdleTimeout: handlerIdleTimeout,
                heartbeatInterval: heartbeatInterval
            ),
            handler: handler
        )
        self.server = server
        XCTAssertNil(server.start())

        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: socketURL.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("socket 未在 5 秒内就绪：\(socketURL.path)")
    }

    private func request(_ action: String, id: String = "r1") -> Data {
        Data(#"{"id":"\#(id)","action":"\#(action)"}"#.utf8)
    }

    private func json(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - 用例

    func testRoundTripThroughRealSocket() async throws {
        try await startServer { request in
            .success(id: request.id, message: "pong")
        }
        let text = try await sendRaw(request("ping"))
        let payload = try json(text)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["message"] as? String, "pong")
        XCTAssertEqual(payload["id"] as? String, "r1", "请求 id 必须原样回来，否则并发调用无法对号入座")
        // 线上约定：响应是**一行** JSON、以换行结尾（按行读的客户端靠它切出最后一行）。
        XCTAssertTrue(text.hasSuffix("\n"), text.debugDescription)
        XCTAssertEqual(text.dropLast().contains("\n"), false, "响应必须是单行：\(text.debugDescription)")
    }

    /// app 自定义编码没以换行结尾时，服务端补上。
    func testResponseWithoutTrailingNewlineGetsOne() async throws {
        struct Bare: ControlResponseEnvelope {
            var message: String
            static func controlFailure(id: String?, code: String, message: String) -> Bare { Bare(message: code) }
            func encodedForWire() throws -> Data { Data(#"{"message":"\#(message)"}"#.utf8) }
        }
        try XCTSkipUnless(ControlSocketLocation.fitsInSunPath(socketURL))
        let server = ControlSocketServer<TestRequest, Bare>(
            socketURL: socketURL, appName: "uTest", handler: { _ in Bare(message: "bare") })
        defer { server.stop() }
        XCTAssertNil(server.start())
        for _ in 0..<250 where !FileManager.default.fileExists(atPath: socketURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = try await sendRaw(request("ping"))
        XCTAssertEqual(text, #"{"message":"bare"}"# + "\n")
    }

    /// 大请求必须**完整**读进来。读循环的收包缓冲只是个 syscall 粒度，任何「按缓冲大小截断 /
    /// 只读一次」的退化都会静默丢尾巴。
    func testLargeRequestIsReceivedIntact() async throws {
        // 900 KB 正文，远超单次 recv 的 64 KiB 缓冲，又在 1 MiB 上限内。
        let contentLength = 900_000
        let content = String(repeating: "A", count: contentLength)
        let payload = Data(
            (#"{"id":"big","action":"terminal-send","path":"/tmp/x","text":""# + content + #""}"#).utf8
        )
        XCTAssertLessThan(payload.count, TestServer.Limits().maxRequestBytes, "夹具自身不能超过协议上限")

        // I/O 预算随已到字节增长，但基线要给足：CI 上走 Unix socket 也要几十毫秒。
        try await startServer(ioTimeout: 15) { request in
            .success(id: request.id, message: "\(request.text?.count ?? -1)|\(request.path ?? "")")
        }

        let response = try await json(sendRaw(payload))
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["id"] as? String, "big")
        XCTAssertEqual(
            response["message"] as? String,
            "\(contentLength)|/tmp/x",
            "正文被截断或串位了：服务端看到的 text 长度与发出的不一致"
        )
    }

    /// 超过 `maxRequestBytes` 的请求回 `request_too_large`，而不是挂死或吃光内存。
    func testOversizedRequestIsRejected() async throws {
        try await startServer { request in .success(id: request.id, message: "不该走到这里") }
        let payload = Data(repeating: UInt8(ascii: "A"), count: TestServer.Limits().maxRequestBytes + 70_000)
        let response = try await json(sendRaw(payload))
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(response["code"] as? String, ControlFailureCode.requestTooLarge)
    }

    /// `SCM_RIGHTS` 随请求交来的 fd 要到得了 handler（经 `ControlRequestContext`），
    /// 而且是同一个文件：handler 往里写，客户端这边读得到。
    func testPassedFileDescriptorReachesTheHandler() async throws {
        try await startServer { request in
            guard let fd = ControlRequestContext.current?.takeFileDescriptor() else {
                return .controlFailure(id: request.id, code: ControlFailureCode.invalidRequest, message: "没收到 fd")
            }
            defer { Darwin.close(fd) }
            let written = Data("来自 handler".utf8).withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
            return .success(id: request.id, message: "wrote \(written)")
        }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "fd-\(UUID().uuidString.prefix(6))")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let local = open(file.path, O_RDWR)
        defer { Darwin.close(local) }

        let payload = try await json(sendRaw(request("sftp-get", id: "fd"), passing: local))
        XCTAssertEqual(payload["ok"] as? Bool, true, "\(payload)")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "来自 handler")
    }

    /// 进度行在响应之前、一行一个 JSON；收尾时攒着的最后几段也要带出来（续传账不能缺尾巴）。
    func testProgressLinesPrecedeTheResponseAndNothingIsLost() async throws {
        try await startServer(handlerIdleTimeout: 5) { request in
            let context = ControlRequestContext.current
            context?.setTotal(300)
            for index in 0..<3 {
                context?.recordSegment(ControlByteRange(offset: Int64(index) * 100, length: 100))
                try? await Task.sleep(for: .milliseconds(index == 2 ? 0 : 700))
            }
            return .success(id: request.id, message: "done")
        }
        let text = try await sendRaw(request("sftp-get", id: "p"))
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let objects = try lines.map { line in
            do { return try json(line) } catch {
                XCTFail("读不懂的一行：\(line.debugDescription)；全文：\(text.debugDescription)")
                throw error
            }
        }
        let events = objects.filter { $0["event"] as? String == "progress" }
        XCTAssertGreaterThanOrEqual(events.count, 2, "处理 1.4 秒，0.5 秒一行，至少两行进度")
        let offsets = events.flatMap { ($0["done"] as? [[String: Any]] ?? []).compactMap { $0["offset"] as? Int } }
        XCTAssertEqual(offsets.sorted(), [0, 100, 200], "三段一段不落、不重复")
        XCTAssertEqual(objects.last?["message"] as? String, "done", "最后一行是响应")
        XCTAssertEqual(events.last?["totalBytes"] as? Int, 300)
    }

    func testMalformedRequestIsRejected() async throws {
        try await startServer { request in .success(id: request.id, message: "不该走到这里") }
        // 灌垃圾：服务端必须自己答一条错误，而不是挂死或崩掉。
        let payload = try await json(sendRaw(Data("not json at all".utf8)))
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["code"] as? String, ControlFailureCode.invalidRequest)
    }

    /// 未知动作同样是 `invalid_request`（动作枚举解码失败）。
    func testUnknownActionIsRejected() async throws {
        try await startServer { request in .success(id: request.id, message: "不该走到这里") }
        let payload = try await json(sendRaw(request("rm-rf")))
        XCTAssertEqual(payload["code"] as? String, ControlFailureCode.invalidRequest)
    }

    func testEmptyRequestIsRejected() async throws {
        try await startServer { request in .success(id: request.id, message: "不该走到这里") }
        let payload = try await json(sendRaw(Data()))
        XCTAssertEqual(payload["code"] as? String, ControlFailureCode.emptyRequest)
    }

    /// 读侧 I/O 超时：客户端只发了半条请求就不动了，服务端不能永远占着这条连接。
    func testRequestIOTimeout() async throws {
        try await startServer(ioTimeout: 0.4) { request in
            .success(id: request.id, message: "不该走到这里")
        }
        let text = try await sendRawWithoutEOF(Data(#"{"action":"pi"#.utf8))
        let payload = try json(text)
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["code"] as? String, ControlFailureCode.requestTimeout)
    }

    /// handler 超时后**晚到**的响应必须被 token 丢弃：不能第二次关同一个 fd
    /// （fd 号会被下一条连接复用，双关就是把别人的连接关掉）。
    func testHandlerTimeoutAndLateResponseDoesNotDisruptLaterClients() async throws {
        try await startServer(handlerIdleTimeout: 0.3) { request in
            if request.action == .hosts {
                try? await Task.sleep(for: .seconds(1.2))
                return .success(id: request.id, message: "太晚了")
            }
            return .success(id: request.id, message: "pong")
        }

        let slow = try await json(sendRaw(request("hosts", id: "slow")))
        XCTAssertEqual(slow["ok"] as? Bool, false)
        XCTAssertEqual(slow["code"] as? String, ControlFailureCode.handlerTimeout)
        XCTAssertEqual(slow["id"] as? String, "slow")

        // 等那条晚到的响应真的落下来，再验后续连接照常工作。
        try await Task.sleep(for: .seconds(1.5))
        let after = try await json(sendRaw(request("ping", id: "after")))
        XCTAssertEqual(after["ok"] as? Bool, true)
        XCTAssertEqual(after["message"] as? String, "pong")
        XCTAssertEqual(after["id"] as? String, "after")
    }

    /// handler 超时是**静默**预算而不是总时长：一直在 `ControlActivity.touch()` 的 handler
    /// 跑得比预算久也不该被掐（慢链路上的大分片传输、长时间刷输出的命令）。
    func testHandlerThatKeepsReportingProgressOutlivesTheIdleBudget() async throws {
        try await startServer(handlerIdleTimeout: 0.3) { request in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                ControlActivity.touch()
            }
            return .success(id: request.id, message: "做完了")
        }
        let payload = try await json(sendRaw(request("hosts")))
        XCTAssertEqual(payload["ok"] as? Bool, true, "持续有进展的 handler 被当成卡死掐掉了")
        XCTAssertEqual(payload["message"] as? String, "做完了")
    }

    /// 脉冲要能穿过子任务：TaskGroup 的分片、`async let` 都继承 task-local。
    func testActivityPulseReachesChildTasks() async throws {
        try await startServer(handlerIdleTimeout: 0.3) { request in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for _ in 0..<10 {
                        try? await Task.sleep(for: .milliseconds(100))
                        ControlActivity.touch()
                    }
                }
            }
            return .success(id: request.id, message: "分片做完了")
        }
        let payload = try await json(sendRaw(request("hosts")))
        XCTAssertEqual(payload["message"] as? String, "分片做完了", "\(payload)")
    }

    /// 处理期间的心跳是前导 `\n`：客户端靠它按静默设 socket 超时，JSON 解析照常。
    func testHeartbeatsPrecedeTheResponseAndKeepItParseable() async throws {
        try await startServer(handlerIdleTimeout: 5, heartbeatInterval: 0.05) { request in
            try? await Task.sleep(for: .milliseconds(400))
            return .success(id: request.id, message: "pong")
        }
        let text = try await sendRaw(request("ping"))
        XCTAssertTrue(text.hasPrefix("\n"), "处理 400 ms、心跳 50 ms，响应前应当有心跳")
        let payload = try json(text)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["message"] as? String, "pong")
    }

    /// 客户端中途走了：下一次写心跳撞上 EPIPE，handler 的任务要被取消 —— 没人要结果的长任务
    /// 不该继续占着资源。
    func testClientDisconnectCancelsTheHandler() async throws {
        let observed = CancellationProbe()
        try await startServer(handlerIdleTimeout: 5, heartbeatInterval: 0.05) { request in
            observed.started()
            for _ in 0..<60 {
                if Task.isCancelled {
                    observed.cancelled()
                    return .success(id: request.id, message: "cancelled")
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return .success(id: request.id, message: "跑完了")
        }
        let fd = try connectSocket()
        Self.sendAllBlocking(fd, request("hosts"))
        Darwin.shutdown(fd, SHUT_WR)
        for _ in 0..<100 where !observed.didStart {
            try await Task.sleep(for: .milliseconds(20))
        }
        Darwin.close(fd)
        for _ in 0..<100 where !observed.wasCancelled {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(observed.wasCancelled, "客户端走了，handler 却没被取消")
    }

    /// `stop()` 时正在处理的请求同样要取消（主开关关了 / app 退出）。
    func testStopCancelsHandlersInFlight() async throws {
        let observed = CancellationProbe()
        try await startServer(handlerIdleTimeout: 5) { request in
            observed.started()
            for _ in 0..<60 {
                if Task.isCancelled {
                    observed.cancelled()
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return .success(id: request.id, message: "done")
        }
        let fd = try connectSocket()
        defer { Darwin.close(fd) }
        Self.sendAllBlocking(fd, request("hosts"))
        Darwin.shutdown(fd, SHUT_WR)
        for _ in 0..<100 where !observed.didStart {
            try await Task.sleep(for: .milliseconds(20))
        }
        server?.stop()
        for _ in 0..<100 where !observed.wasCancelled {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(observed.wasCancelled, "stop() 没取消正在处理的 handler")
    }

    /// 长连接与短请求的槽位分开：长请求占满自己的份额后，新的长请求拿 `server_busy`，
    /// 但 `ping` 这类短请求照样进得来 —— 并行下载不该把 `run` 挤掉。
    func testTransfersCannotStarveShortRequests() async throws {
        try await startServer(maxActiveClients: 4, maxLongLivedClients: 1) { request in
            if request.action == .sftpGet {
                try? await Task.sleep(for: .seconds(1))
                return .success(id: request.id, message: "传完了")
            }
            return .success(id: request.id, message: "pong")
        }
        // 第一片占住唯一的长连接槽位：发完请求就先不读，最后再收它的响应。
        let first = try connectSocket()
        Self.sendAllBlocking(first, Data(#"{"id":"t1","action":"sftp-get","path":"/a"}"#.utf8))
        Darwin.shutdown(first, SHUT_WR)
        try await Task.sleep(for: .milliseconds(300))

        let second = try await json(sendRaw(Data(#"{"id":"t2","action":"sftp-get","path":"/b"}"#.utf8)))
        XCTAssertEqual(second["code"] as? String, ControlFailureCode.serverBusy, "长连接槽位满了，第二片应当被拒")
        XCTAssertEqual(second["id"] as? String, "t2")

        // `terminal-wait` 同样占长连接槽位。
        let wait = try await json(sendRaw(request("terminal-wait", id: "w")))
        XCTAssertEqual(wait["code"] as? String, ControlFailureCode.serverBusy)

        let ping = try await json(sendRaw(request("ping", id: "p")))
        XCTAssertEqual(ping["ok"] as? Bool, true, "长请求占满不该挤掉短请求")

        let done = try await json(drain(first))
        Darwin.close(first)
        XCTAssertEqual(done["message"] as? String, "传完了")
    }

    /// 并发上限：占满槽位后，新连接**先收到 `server_busy` 再**被关掉（不排队、不吃内存），
    /// 已占位的那条仍然拿到自己的响应。
    ///
    /// 关键是那条响应：只 shutdown + close 的话客户端只看得到空响应，分不清「服务端忙、退避
    /// 重试就好」与「socket 坏了、该报错」。
    func testConcurrentClientCapAnswersServerBusyBeforeClosing() async throws {
        try await startServer(maxActiveClients: 1, ioTimeout: 1.5) { request in
            .success(id: request.id, message: "pong")
        }

        // 第一条连接握住槽位：只发半条请求，不发 EOF，服务端 worker 卡在读上。
        let holder = try connectSocket()
        let partial = Data(#"{"action":"pi"#.utf8)
        _ = partial.withUnsafeBytes { Darwin.send(holder, $0.baseAddress, partial.count, 0) }

        // 第二条连接：槽位满 → register 返回 nil → 回一条 server_busy 再 shutdown+close。
        let rejected = try await sendRaw(request("ping", id: "rejected"))
        XCTAssertFalse(rejected.isEmpty, "超出并发上限的连接必须先拿到一条响应，而不是空的 EOF")
        let payload = try json(rejected)
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["code"] as? String, ControlFailureCode.serverBusy, "被拒的连接必须能和「socket 坏了」区分开")
        XCTAssertTrue((payload["message"] as? String ?? "").contains("uTest"), "错误码要配一句能给人看的话")

        // 收尾：第一条连接读到自己的超时响应，槽位随之释放。
        let text = try await drain(holder)
        Darwin.close(holder)
        XCTAssertEqual(try json(text)["code"] as? String, ControlFailureCode.requestTimeout)
    }

    func testStopRemovesTheSocketFile() async throws {
        try await startServer { request in .success(id: request.id, message: "ok") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertTrue(server?.isRunning == true)
        server?.stop()
        XCTAssertFalse(server?.isRunning == true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketURL.path),
            "主开关关掉后 socket 必须消失，客户端才能报「app 没在跑」而不是连上再被拒"
        )
    }

    /// 关了再开：新一代照常服务（generation 递增后旧连接的收尾不能误伤新 listener）。
    func testRestartAfterStopServesAgain() async throws {
        try await startServer { request in .success(id: request.id, message: "ok") }
        server?.stop()
        XCTAssertNil(server?.start())
        for _ in 0..<250 where !FileManager.default.fileExists(atPath: socketURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let payload = try await json(sendRaw(request("ping")))
        XCTAssertEqual(payload["ok"] as? Bool, true)
    }

    /// 上一个实例被强杀留下的残留文件（没人监听）要被清掉、重新 bind。
    func testStaleSocketFileIsReplaced() async throws {
        try XCTSkipUnless(ControlSocketLocation.fitsInSunPath(socketURL))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try XCTUnwrap(UnixSocketAddress(path: socketURL.path))
        XCTAssertEqual(address.withSockaddr { Darwin.bind(fd, $0, $1) }, 0)
        Darwin.close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertFalse(ControlSocketLocation.isSocketServed(socketURL))

        try await startServer { request in .success(id: request.id, message: "fresh") }
        var payload: [String: Any] = [:]
        for _ in 0..<50 {
            if ControlSocketLocation.isSocketServed(socketURL) {
                payload = try await json(sendRaw(request("ping")))
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(payload["message"] as? String, "fresh")
    }

    /// 第二个实例绝不能抢走已被服务的路径 —— 抢了会留下孤儿 listener，
    /// 表现为「app 开着，CLI 却连不上」。
    func testSecondServerDoesNotStealAServedSocket() async throws {
        try await startServer { request in .success(id: request.id, message: "first") }
        let intruder = TestServer(
            socketURL: socketURL,
            appName: "uTest",
            handler: { request in .success(id: request.id, message: "intruder") }
        )
        intruder.start()
        defer { intruder.stop() }
        try await Task.sleep(for: .milliseconds(400))

        let payload = try await json(sendRaw(request("ping")))
        XCTAssertEqual(payload["message"] as? String, "first", "socket 被后来者抢走了")
    }

    /// 长用户名会把 `sun_path` 顶穿 104 字节。此时必须**不 bind**、直接回错误串
    /// （进 accept 循环就成了每 2 秒重试一次的死循环）。
    func testTooLongSocketPathIsRefusedBeforeBinding() {
        let long = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: String(repeating: "u", count: 200) + ".sock")
        let server = TestServer(socketURL: long, appName: "uTest", handler: { _ in .success(id: nil, message: "") })
        let error = server.start()
        XCTAssertNotNil(error, "路径超过 sun_path 上限必须拒绝启动")
        XCTAssertTrue(error?.contains("socket 路径过长") == true, error ?? "")
        // 客户端的 socket 覆盖变量只管客户端去哪里找，改不了这里的监听位置，别拿它当办法。
        XCTAssertFalse(error?.contains("_CONTROL_SOCKET") == true, error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: long.path))
        XCTAssertFalse(server.isRunning)
    }

    // MARK: - 裸 socket 工具（**必须离开主线程**）

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        // 必须开 SO_NOSIGPIPE：并发上限用例里服务端会先把连接关掉，此时再 send 就会收到
        // SIGPIPE —— 默认处置是**杀死测试进程**。
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = try XCTUnwrap(UnixSocketAddress(path: socketURL.path))
        let connected = address.withSockaddr { Darwin.connect(fd, $0, $1) }
        XCTAssertEqual(connected, 0, "connect 失败：\(String(cString: strerror(errno)))")
        return fd
    }

    private func sendRaw(_ payload: Data, passing passed: Int32? = nil) async throws -> String {
        let fd = try connectSocket()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                if let passed {
                    Self.sendPassingDescriptor(fd, payload, passed)
                } else {
                    Self.sendAllBlocking(fd, payload)
                }
                Darwin.shutdown(fd, SHUT_WR)
                let text = Self.drainBlocking(fd)
                Darwin.close(fd)
                continuation.resume(returning: text)
            }
        }
    }

    /// 发一半就不发 EOF，让服务端在读侧等到超时。
    private func sendRawWithoutEOF(_ payload: Data) async throws -> String {
        let fd = try connectSocket()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                Self.sendAllBlocking(fd, payload)
                let text = Self.drainBlocking(fd)
                Darwin.close(fd)
                continuation.resume(returning: text)
            }
        }
    }

    /// 用 `sendmsg` + `SCM_RIGHTS` 把 `passed` 挂在整段请求上发出去（与 utermctl 同形）。
    nonisolated private static func sendPassingDescriptor(_ fd: Int32, _ payload: Data, _ passed: Int32) {
        var control = [UInt8](repeating: 0, count: MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size)
        control.withUnsafeMutableBytes { raw in
            var header = cmsghdr(
                cmsg_len: socklen_t(raw.count), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS)
            withUnsafeBytes(of: &header) { raw.copyMemory(from: $0) }
            var descriptor = passed
            withUnsafeBytes(of: &descriptor) {
                UnsafeMutableRawBufferPointer(rebasing: raw[MemoryLayout<cmsghdr>.size...]).copyMemory(from: $0)
            }
        }
        var bytes = [UInt8](payload)
        bytes.withUnsafeMutableBytes { body in
            control.withUnsafeMutableBytes { controlBytes in
                var vector = iovec(iov_base: body.baseAddress, iov_len: body.count)
                withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var message = msghdr()
                    message.msg_iov = vectorPointer
                    message.msg_iovlen = 1
                    message.msg_control = controlBytes.baseAddress
                    message.msg_controllen = socklen_t(controlBytes.count)
                    _ = sendmsg(fd, &message, 0)
                }
            }
        }
    }

    /// 把整个 payload 写完。阻塞 `send` 被信号打断后会返回短计数，大请求下这一点不能赌。
    /// 返回值 <= 0（对端已关 / EPIPE）时直接停，给并发上限那条用例留出正常出口。
    nonisolated private static func sendAllBlocking(_ fd: Int32, _ payload: Data) {
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, base + sent, raw.count - sent, 0)
                if count <= 0 {
                    if count < 0 && errno == EINTR { continue }
                    return
                }
                sent += count
            }
        }
    }

    private func drain(_ fd: Int32) async throws -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: Self.drainBlocking(fd))
            }
        }
    }

    nonisolated private static func drainBlocking(_ fd: Int32) -> String {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            received.append(buffer, count: count)
        }
        return String(data: received, encoding: .utf8) ?? ""
    }
}

/// handler 在 MainActor 上写、测试轮询读。
private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var startedFlag = false
    private var cancelledFlag = false

    func started() { lock.withLock { startedFlag = true } }
    func cancelled() { lock.withLock { cancelledFlag = true } }
    var didStart: Bool { lock.withLock { startedFlag } }
    var wasCancelled: Bool { lock.withLock { cancelledFlag } }
}

#endif
