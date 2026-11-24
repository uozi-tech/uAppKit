import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import USSHCore
import XCTest

/// 本机真实的 OpenSSH 服务端：以当前用户身份跑 `/usr/sbin/sshd -D -e`，监听 127.0.0.1 的一个空闲端口，
/// 配置、主机密钥、authorized_keys 都在临时目录里。起不来（没有 sshd、端口被占、沙盒不允许）就 `XCTSkip`。
///
/// 非 root 的 sshd 校验不了系统口令（`UsePAM no`），所以只测公钥认证。
final class OpenSSHFixture: Sendable {
    let port: Int
    let directory: URL
    let username: String
    let ed25519Key: NIOSSHPrivateKey
    let p256Key: NIOSSHPrivateKey
    let p384Key: NIOSSHPrivateKey
    let hostKey: NIOSSHPublicKey
    private let process: NIOLockedValueBox<Process?>
    private let log: NIOLockedValueBox<String>

    private init(port: Int, directory: URL, username: String, keys: [NIOSSHPrivateKey], hostKey: NIOSSHPublicKey,
                 process: Process, log: NIOLockedValueBox<String>) {
        self.port = port
        self.directory = directory
        self.username = username
        self.ed25519Key = keys[0]
        self.p256Key = keys[1]
        self.p384Key = keys[2]
        self.hostKey = hostKey
        self.process = NIOLockedValueBox(process)
        self.log = log
    }

    static let sshd = "/usr/sbin/sshd"
    static let sshKeygen = "/usr/bin/ssh-keygen"

    static func start() async throws -> OpenSSHFixture {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: sshd), fileManager.isExecutableFile(atPath: sshKeygen) else {
            throw XCTSkip("没有 \(sshd) 或 \(sshKeygen)")
        }
        let directory = fileManager.temporaryDirectory.appendingPathComponent("usshcore-sshd-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let hostKeyPath = directory.appendingPathComponent("host_ed25519").path
        try run(sshKeygen, ["-q", "-t", "ed25519", "-N", "", "-f", hostKeyPath])
        let hostKeyLine = try String(contentsOfFile: hostKeyPath + ".pub", encoding: .utf8)
        let hostKey = try NIOSSHPublicKey(openSSHPublicKey: hostKeyLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").prefix(2).joined(separator: " "))

        let keys = [
            NIOSSHPrivateKey(ed25519Key: .init()),
            NIOSSHPrivateKey(p256Key: .init()),
            NIOSSHPrivateKey(p384Key: .init()),
        ]
        let authorizedKeys = keys.map { String(openSSHPublicKey: $0.publicKey) }.joined(separator: "\n") + "\n"
        let authorizedKeysPath = directory.appendingPathComponent("authorized_keys").path
        try authorizedKeys.write(toFile: authorizedKeysPath, atomically: true, encoding: .utf8)

        var lastError = ""
        for _ in 0..<3 {
            let port = try await freePort()
            let configPath = directory.appendingPathComponent("sshd_config").path
            let config = """
            ListenAddress 127.0.0.1:\(port)
            HostKey \(hostKeyPath)
            AuthorizedKeysFile \(authorizedKeysPath)
            UsePAM no
            StrictModes no
            PidFile none
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            PermitTTY yes
            AllowTcpForwarding yes
            AcceptEnv LANG USSH_*
            MaxSessions 64
            MaxStartups 64
            LogLevel INFO
            Subsystem sftp /usr/libexec/sftp-server

            """
            try config.write(toFile: configPath, atomically: true, encoding: .utf8)

            let log = NIOLockedValueBox("")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sshd)
            process.arguments = ["-D", "-e", "-f", configPath]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    // EOF：不摘掉的话会一直被回调、空转。
                    handle.readabilityHandler = nil
                    return
                }
                log.withLockedValue { $0 += String(decoding: data, as: UTF8.self) }
            }
            do {
                try process.run()
            } catch {
                throw XCTSkip("起不了 sshd：\(error)")
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline, process.isRunning,
                  !log.withLockedValue({ $0.contains("Server listening") }) {
                try await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning, log.withLockedValue({ $0.contains("Server listening") }) {
                return OpenSSHFixture(port: port, directory: directory, username: NSUserName(), keys: keys,
                                      hostKey: hostKey, process: process, log: log)
            }
            lastError = log.withLockedValue { $0 }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        try? fileManager.removeItem(at: directory)
        throw XCTSkip("sshd 没起来：\(lastError)")
    }

    var sshdLog: String { log.withLockedValue { $0 } }

    var pid: Int32 { process.withLockedValue { $0?.processIdentifier ?? 0 } }

    /// 杀掉 sshd 和它的每连接子进程（OpenSSH 10 的 sshd-session）。
    func kill() {
        guard let process = process.withLockedValue({ $0 }) else { return }
        let pid = process.processIdentifier
        // 先收集整棵子树再杀：认证后的「user@notty」进程是 sshd-session 监控进程的子进程，监控进程一死它就
        // 被 launchd 收养、手里还攥着 TCP 连接，事后就找不到了。
        for child in Self.descendants(of: pid).reversed() {
            Darwin.kill(child, SIGKILL)
        }
        // 不用 waitUntilExit：它在测试的主线程上转 run loop，可能等不到终止通知。
        if process.isRunning { Darwin.kill(pid, SIGKILL) }
        for _ in 0..<200 where process.isRunning {
            usleep(10_000)
        }
    }

    func stop() {
        kill()
        process.withLockedValue { $0 = nil }
        try? FileManager.default.removeItem(at: directory)
    }

    func configuration(_ key: NIOSSHPrivateKey? = nil) -> SSHClient.Configuration {
        SSHClient.Configuration(
            authentication: .privateKey(key ?? ed25519Key, username: username),
            hostKeyValidation: .trustedKeys([hostKey]),
            connectTimeout: .seconds(5),
            handshakeTimeout: .seconds(10))
    }

    func connect(_ key: NIOSSHPrivateKey? = nil) async throws -> SSHClient {
        try await SSHClient.connect(host: "127.0.0.1", port: port, configuration: configuration(key))
    }

    private static func descendants(of pid: Int32) -> [Int32] {
        let output = (try? run("/usr/bin/pgrep", ["-P", String(pid)], allowFailure: true)) ?? ""
        let children = output.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        return children.flatMap { [$0] + descendants(of: $0) }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning { usleep(5_000) }
        if !allowFailure, process.terminationStatus != 0 {
            throw XCTSkip("\(executable) \(arguments.joined(separator: " ")) 失败（\(process.terminationStatus)）")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func freePort() async throws -> Int {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = channel.localAddress?.port ?? 0
        try await channel.close()
        return port
    }
}
