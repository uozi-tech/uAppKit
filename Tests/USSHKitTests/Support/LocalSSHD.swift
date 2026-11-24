import Foundation
import NIOPosix
import XCTest

/// 本机真实的 `/usr/sbin/sshd`（以当前用户身份、`-D -e`、127.0.0.1 的空闲端口，文件都在临时目录）。
/// 只做 USSHKit 层要的：一把 `ssh-keygen` 生成的 ed25519 用户私钥（OpenSSH 容器格式，按 `SSHCredential.privateKey`
/// 交给 USSHKit）、可选 RSA 主机密钥、追加配置、按日志数连接。起不来就 `XCTSkip`。
/// （USSHCore 的测试里有一份更全的 `OpenSSHFixture`，测试 target 之间不能共用源码。）
final class LocalSSHD: @unchecked Sendable {
    let port: Int
    let username: String
    let userKeyPEM: String
    private let directory: URL
    private let process: Process
    private let lock = NSLock()
    private var output = ""

    var log: String { lock.withLock { output } }

    /// sshd 接受过的 TCP 连接数（每条连接记一行 `Connection from …`，LogLevel VERBOSE 起就有）。
    var connections: Int { log.components(separatedBy: "Connection from 127.0.0.1").count - 1 }

    private init(port: Int, username: String, userKeyPEM: String, directory: URL, process: Process) {
        self.port = port
        self.username = username
        self.userKeyPEM = userKeyPEM
        self.directory = directory
        self.process = process
    }

    static func start(extraConfig: [String], rsaHostKey: Bool = false) async throws -> LocalSSHD {
        let sshd = "/usr/sbin/sshd", keygen = "/usr/bin/ssh-keygen"
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: sshd), fileManager.isExecutableFile(atPath: keygen) else {
            throw XCTSkip("没有 \(sshd) 或 \(keygen)")
        }
        let directory = fileManager.temporaryDirectory.appendingPathComponent("usshkit-sshd-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let hostKeyPath = directory.appendingPathComponent(rsaHostKey ? "host_rsa" : "host_ed25519").path
        try run(keygen, ["-q", "-t", rsaHostKey ? "rsa" : "ed25519"] + (rsaHostKey ? ["-b", "2048"] : [])
                + ["-N", "", "-f", hostKeyPath])
        let userKeyPath = directory.appendingPathComponent("user_ed25519").path
        try run(keygen, ["-q", "-t", "ed25519", "-N", "", "-f", userKeyPath])
        let authorizedKeysPath = directory.appendingPathComponent("authorized_keys").path
        try fileManager.copyItem(atPath: userKeyPath + ".pub", toPath: authorizedKeysPath)
        let userKeyPEM = try String(contentsOfFile: userKeyPath, encoding: .utf8)

        var lastLog = ""
        for _ in 0..<3 {
            let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .bind(host: "127.0.0.1", port: 0).get()
            let port = listener.localAddress?.port ?? 0
            try await listener.close()

            let configPath = directory.appendingPathComponent("sshd_config").path
            let config = ([
                "ListenAddress 127.0.0.1:\(port)",
                "HostKey \(hostKeyPath)",
                "AuthorizedKeysFile \(authorizedKeysPath)",
                "UsePAM no", "StrictModes no", "PidFile none",
                "PasswordAuthentication no", "KbdInteractiveAuthentication no",
                "MaxStartups 64", "LogLevel VERBOSE",
            ] + extraConfig).joined(separator: "\n") + "\n"
            try config.write(toFile: configPath, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: sshd)
            process.arguments = ["-D", "-e", "-f", configPath]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            let server = LocalSSHD(port: port, username: NSUserName(), userKeyPEM: userKeyPEM,
                                   directory: directory, process: process)
            pipe.fileHandleForReading.readabilityHandler = { [weak server] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                server?.append(String(decoding: data, as: UTF8.self))
            }
            try process.run()
            if await server.waitUntilListening() { return server }
            lastLog = server.log
            server.stop(keepDirectory: true)
        }
        try? fileManager.removeItem(at: directory)
        throw XCTSkip("sshd 没起来：\(lastLog)")
    }

    private func append(_ text: String) { lock.withLock { output += text } }

    private func waitUntilListening() async -> Bool {
        for _ in 0..<200 {
            guard process.isRunning else { return false }
            if log.contains("Server listening") { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// 等日志里出现至少 `count` 条连接（sshd 的日志是异步写的）。
    func waitForConnections(_ count: Int) async {
        for _ in 0..<300 where connections < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func stop(keepDirectory: Bool = false) {
        let pid = process.processIdentifier
        let children = (try? Self.run("/usr/bin/pgrep", ["-P", String(pid)], allowFailure: true)) ?? ""
        for child in children.split(whereSeparator: \.isNewline).compactMap({ Int32($0) }) {
            kill(child, SIGKILL)
        }
        if process.isRunning { kill(pid, SIGKILL) }
        if !keepDirectory { try? FileManager.default.removeItem(at: directory) }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
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
}
