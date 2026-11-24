import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import XCTest

@testable import USSHCore

/// 与本机真实的 OpenSSH sshd 互通：只给 NIOSSH 客户端一种我们的加密方式，用 ed25519 密钥登录、跑一条命令、
/// 收回足够多的输出让 sshd 按 `RekeyLimit` 主动换钥。这是线上兼容性的唯一真凭据（其余测试只证明自洽）。
///
/// sshd 以当前用户身份跑在 127.0.0.1 的临时端口上，配置、主机密钥、authorized_keys 都在临时目录里。
/// 起不来（没有 sshd、端口不通、被沙盒拦）就跳过。设 `USSH_SKIP_SSHD_INTEROP=1` 也跳过。
final class TransportProtectionOpenSSHInteropTests: XCTestCase {
    private static let sshdPath = "/usr/sbin/sshd"
    private static let outputBytes = 300_000

    func testEachSchemeAgainstLocalOpenSSH() throws {
        if ProcessInfo.processInfo.environment["USSH_SKIP_SSHD_INTEROP"] == "1" {
            throw XCTSkip("USSH_SKIP_SSHD_INTEROP=1")
        }
        guard FileManager.default.isExecutableFile(atPath: Self.sshdPath) else {
            throw XCTSkip("没有 \(Self.sshdPath)")
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let userKey = Curve25519.Signing.PrivateKey()

        // HMAC-SHA2-512 要 64 字节 MAC 密钥：只有 ecdh-sha2-nistp521（SHA-512）时 NIOSSH 推得出来，单独一台 sshd。
        let runs: [(kex: String, schemes: [SSHTransportProtections.Scheme])] = [
            ("curve25519-sha256,ecdh-sha2-nistp384,ecdh-sha2-nistp256", SSHTransportProtections.modern + SSHTransportProtections.legacy),
            ("ecdh-sha2-nistp521", SSHTransportProtections.requiringKeyExtension),
        ]
        for run in runs {
            let server = try LocalSSHD.start(sshdPath: Self.sshdPath, userKey: userKey.publicKey, kexAlgorithms: run.kex)
            defer { server.stop() }
            for scheme in run.schemes {
                let label = "\(scheme.cipherName) + \(scheme.macName!) [\(run.kex)]"
                let kexBefore = server.keyExchangeCount()
                let result = try Self.exec(
                    command: "yes uterm-interop | head -c \(Self.outputBytes)",
                    port: server.port,
                    hostKey: server.hostKey,
                    userKey: userKey,
                    scheme: scheme,
                    group: group
                )
                XCTAssertEqual(result.exitStatus, 0, "\(label) stderr: \(String(decoding: result.stderr, as: UTF8.self)) sshd: \(server.log())")
                XCTAssertEqual(result.stdout.count, Self.outputBytes, label)
                let line = Array("uterm-interop\n".utf8)
                let expected = (0..<(Self.outputBytes / line.count + 1)).flatMap { _ in line }.prefix(Self.outputBytes)
                XCTAssertTrue(result.stdout.elementsEqual(expected), label)
                // 首次密钥交换 + 至少一次 sshd 按 RekeyLimit 发起的换钥。
                XCTAssertGreaterThanOrEqual(server.keyExchangeCount() - kexBefore, 2, "\(label) 没有发生换钥")
                // sshd 自己记下的协商结果（DEBUG1）：确实是这一对。
                XCTAssertTrue(
                    server.log().contains("cipher: \(scheme.cipherName) MAC: \(scheme.macName!) compression: none"),
                    "\(label) sshd 日志里没有对应的协商记录"
                )
            }
        }
    }

    // MARK: 一次 exec

    private struct ExecResult: Sendable {
        var stdout: [UInt8] = []
        var stderr: [UInt8] = []
        var exitStatus: Int?
    }

    private struct Timeout: Error {}

    private static func exec(
        command: String,
        port: Int,
        hostKey: NIOSSHPublicKey,
        userKey: Curve25519.Signing.PrivateKey,
        scheme: SSHTransportProtections.Scheme,
        group: EventLoopGroup
    ) throws -> ExecResult {
        let username = NSUserName()
        let userAuth = KeyAuth(username: username, key: NIOSSHPrivateKey(ed25519Key: userKey))
        let hostAuth = PinnedHostKey(expected: hostKey)
        let schemes: [SSHTransportProtections.Scheme] = [scheme]
        let bootstrap = ClientBootstrap(group: group).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let handler = NIOSSHHandler(
                    role: .client(
                        .init(userAuthDelegate: userAuth, serverAuthDelegate: hostAuth, transportProtectionSchemes: schemes)
                    ),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                try channel.pipeline.syncOperations.addHandler(handler)
            }
        }
        let channel = try bootstrap.connect(host: "127.0.0.1", port: port).wait()
        defer { _ = try? channel.close().wait() }

        let resultPromise = channel.eventLoop.makePromise(of: ExecResult.self)
        let once = NIOLockedValueBox(false)
        let finish: @Sendable (Result<ExecResult, Error>) -> Void = { result in
            let first = once.withLockedValue { done in
                defer { done = true }
                return !done
            }
            if first { resultPromise.completeWith(result) }
        }
        channel.eventLoop.scheduleTask(in: .seconds(30)) { finish(.failure(Timeout())) }
        channel.closeFuture.whenComplete { _ in finish(.failure(ChannelError.ioOnClosedChannel)) }

        try channel.eventLoop.submit {
            let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
            ssh.createChannel(nil, channelType: .session) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(ExecHandler(command: command, finish: finish))
                }
            }
        }.wait()
        return try resultPromise.futureResult.wait()
    }

    private final class KeyAuth: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
        private let username: String
        private var key: NIOSSHPrivateKey?

        init(username: String, key: NIOSSHPrivateKey) {
            self.username = username
            self.key = key
        }

        func nextAuthenticationType(
            availableMethods: NIOSSHAvailableUserAuthenticationMethods,
            nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
        ) {
            guard availableMethods.contains(.publicKey), let key = self.key else {
                nextChallengePromise.succeed(nil)
                return
            }
            self.key = nil
            nextChallengePromise.succeed(
                .init(username: self.username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key)))
            )
        }
    }

    private final class PinnedHostKey: NIOSSHClientServerAuthenticationDelegate, Sendable {
        let expected: NIOSSHPublicKey

        init(expected: NIOSSHPublicKey) {
            self.expected = expected
        }

        func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
            if hostKey == self.expected {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(ChannelError.badInterfaceAddressFamily)
            }
        }
    }

    private final class ExecHandler: ChannelDuplexHandler {
        typealias InboundIn = SSHChannelData
        typealias OutboundIn = SSHChannelData
        typealias OutboundOut = SSHChannelData

        private let command: String
        private let finish: @Sendable (Result<ExecResult, Error>) -> Void
        private var result = ExecResult()

        init(command: String, finish: @escaping @Sendable (Result<ExecResult, Error>) -> Void) {
            self.command = command
            self.finish = finish
        }

        func handlerAdded(context: ChannelHandlerContext) {
            do {
                try context.channel.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            } catch {
                self.finish(.failure(error))
            }
        }

        func channelActive(context: ChannelHandlerContext) {
            let request = SSHChannelRequestEvent.ExecRequest(command: self.command, wantReply: true)
            context.triggerUserOutboundEvent(request, promise: nil)
            context.fireChannelActive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let message = self.unwrapInboundIn(data)
            guard case .byteBuffer(let buffer) = message.data else { return }
            switch message.type {
            case .channel: self.result.stdout += buffer.readableBytesView
            case .stdErr: self.result.stderr += buffer.readableBytesView
            default: break
            }
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let status = event as? SSHChannelRequestEvent.ExitStatus {
                self.result.exitStatus = status.exitStatus
            }
            context.fireUserInboundEventTriggered(event)
        }

        func channelInactive(context: ChannelHandlerContext) {
            self.finish(.success(self.result))
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            self.finish(.failure(error))
            context.close(promise: nil)
        }
    }
}

// MARK: - 临时 sshd

private final class LocalSSHD {
    let port: Int
    let hostKey: NIOSSHPublicKey
    private let process: Process
    private let directory: URL
    private let logPipe: Pipe
    private let logData = NIOLockedValueBox(Data())

    private init(port: Int, hostKey: NIOSSHPublicKey, process: Process, directory: URL, logPipe: Pipe) {
        self.port = port
        self.hostKey = hostKey
        self.process = process
        self.directory = directory
        self.logPipe = logPipe
    }

    func log() -> String {
        String(decoding: self.logData.withLockedValue { $0 }, as: UTF8.self)
    }

    /// sshd 日志里「发出 KEXINIT」的次数（LogLevel DEBUG1）。
    func keyExchangeCount() -> Int {
        self.log().components(separatedBy: "SSH2_MSG_KEXINIT sent").count - 1
    }

    static func start(sshdPath: String, userKey: Curve25519.Signing.PublicKey, kexAlgorithms: String) throws -> LocalSSHD {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ussh-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hostKeyPath = directory.appendingPathComponent("host_ed25519").path
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", hostKeyPath]
        keygen.standardOutput = FileHandle.nullDevice
        keygen.standardError = FileHandle.nullDevice
        try keygen.run()
        keygen.waitUntilExit()
        guard keygen.terminationStatus == 0 else { throw XCTSkip("ssh-keygen 失败") }
        let hostPublic = try String(contentsOfFile: hostKeyPath + ".pub", encoding: .utf8)
        let hostKey = try NIOSSHPublicKey(openSSHPublicKey: hostPublic.trimmingCharacters(in: .whitespacesAndNewlines))

        // authorized_keys：ssh-ed25519 blob = string "ssh-ed25519" ‖ string 32 字节公钥。
        var blob = ByteBuffer()
        blob.writeSSHWireString("ssh-ed25519")
        blob.writeSSHWireString(Array(userKey.rawRepresentation))
        let authorized = "ssh-ed25519 \(Data(blob.readableBytesView).base64EncodedString()) interop\n"
        let authorizedPath = directory.appendingPathComponent("authorized_keys").path
        try authorized.write(toFile: authorizedPath, atomically: true, encoding: .utf8)

        let port = try Self.freePort()
        let config = """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(hostKeyPath)
            HostKeyAlgorithms ssh-ed25519
            AuthorizedKeysFile \(authorizedPath)
            UsePAM no
            StrictModes no
            PidFile none
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            PubkeyAuthentication yes
            KexAlgorithms \(kexAlgorithms)
            Ciphers aes128-ctr,aes192-ctr,aes256-ctr
            MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha1-etm@openssh.com,hmac-sha2-256,hmac-sha2-512,hmac-sha1
            RekeyLimit 64K
            LogLevel DEBUG1
            """
        let configPath = directory.appendingPathComponent("sshd_config").path
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshdPath)
        process.arguments = ["-D", "-e", "-f", configPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let server = LocalSSHD(port: port, hostKey: hostKey, process: process, directory: directory, logPipe: pipe)
        pipe.fileHandleForReading.readabilityHandler = { [logData = server.logData] handle in
            let chunk = handle.availableData
            logData.withLockedValue { $0.append(chunk) }
        }
        try process.run()

        // 等端口可连。
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !process.isRunning {
                let log = server.log()
                server.stop()
                throw XCTSkip("sshd 没起来：\(log)")
            }
            if Self.canConnect(port: port) { return server }
            usleep(50_000)
        }
        let log = server.log()
        server.stop()
        throw XCTSkip("sshd 端口 \(port) 5 秒内不可连：\(log)")
    }

    func stop() {
        if self.process.isRunning {
            self.process.terminate()
            self.process.waitUntilExit()
        }
        self.logPipe.fileHandleForReading.readabilityHandler = nil
        try? FileManager.default.removeItem(at: self.directory)
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("socket() 失败") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw XCTSkip("取不到空闲端口") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
