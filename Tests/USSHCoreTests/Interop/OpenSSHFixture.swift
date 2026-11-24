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
///
/// `Options` 调主机密钥（ed25519 / 只有 RSA）、日志级别，以及在默认配置**之前**插入的 sshd 配置行
/// （sshd 对大多数选项取第一次出现的值，所以插在前面就能覆盖默认）。authorized_keys 里另有两把
/// `ssh-keygen` 生成的 RSA 用户密钥（2048、4096 位，`rsa2048Key` / `rsa4096Key`）。
final class OpenSSHFixture: Sendable {
    struct Options: Sendable {
        /// 主机密钥：`nil` = ed25519；给位数 = 只有一把这么长的 RSA 主机密钥。
        var rsaHostKeyBits: Int?
        /// sshd 的 LogLevel（`DEBUG1` 才有协商结果与 KEXINIT 的记录）。
        var logLevel = "INFO"
        /// 插在默认配置之前的行，例如 `KexAlgorithms diffie-hellman-group14-sha256`。
        var extraConfig: [String] = []

        init(rsaHostKeyBits: Int? = nil, logLevel: String = "INFO", extraConfig: [String] = []) {
            self.rsaHostKeyBits = rsaHostKeyBits
            self.logLevel = logLevel
            self.extraConfig = extraConfig
        }
    }

    let port: Int
    let directory: URL
    let username: String
    let ed25519Key: NIOSSHPrivateKey
    let p256Key: NIOSSHPrivateKey
    let p384Key: NIOSSHPrivateKey
    let rsa2048Key: SSHRSAPrivateKey
    let rsa4096Key: SSHRSAPrivateKey
    let hostKey: NIOSSHPublicKey
    /// 主机公钥文件（`ssh-keygen -lf` 用）。
    let hostKeyPublicPath: String
    private let process: NIOLockedValueBox<Process?>
    private let log: NIOLockedValueBox<String>

    private init(port: Int, directory: URL, username: String, keys: [NIOSSHPrivateKey], rsaKeys: [SSHRSAPrivateKey],
                 hostKey: NIOSSHPublicKey, hostKeyPublicPath: String, process: Process, log: NIOLockedValueBox<String>) {
        self.port = port
        self.directory = directory
        self.username = username
        self.ed25519Key = keys[0]
        self.p256Key = keys[1]
        self.p384Key = keys[2]
        self.rsa2048Key = rsaKeys[0]
        self.rsa4096Key = rsaKeys[1]
        self.hostKey = hostKey
        self.hostKeyPublicPath = hostKeyPublicPath
        self.process = NIOLockedValueBox(process)
        self.log = log
    }

    /// `ssh-keygen -t rsa -m PEM` 生成的用户密钥（私钥, OpenSSH 公钥行）。4096 位要好几秒，整个进程只生成一次。
    private static let rsaUserKeys = NIOLockedValueBox<[(SSHRSAPrivateKey, String)]?>(nil)

    private static func generatedRSAUserKeys(in directory: URL) throws -> [(SSHRSAPrivateKey, String)] {
        try rsaUserKeys.withLockedValue { cached in
            if let cached { return cached }
            var keys: [(SSHRSAPrivateKey, String)] = []
            for bits in [2048, 4096] {
                let path = directory.appendingPathComponent("user_rsa\(bits)").path
                try run(sshKeygen, ["-q", "-t", "rsa", "-b", String(bits), "-m", "PEM", "-N", "", "-f", path])
                let key = try SSHRSAPrivateKey(pemRepresentation: String(contentsOfFile: path, encoding: .utf8))
                let line = try String(contentsOfFile: path + ".pub", encoding: .utf8)
                keys.append((key, line.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            cached = keys
            return keys
        }
    }

    static let sshd = "/usr/sbin/sshd"
    static let sshKeygen = "/usr/bin/ssh-keygen"

    static func start(_ options: Options = Options()) async throws -> OpenSSHFixture {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: sshd), fileManager.isExecutableFile(atPath: sshKeygen) else {
            throw XCTSkip("没有 \(sshd) 或 \(sshKeygen)")
        }
        let directory = fileManager.temporaryDirectory.appendingPathComponent("usshcore-sshd-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // RSA 主机 / 用户公钥要经 NIOSSH 解析，先登记（建连接时本来也会登记）。
        SSHAlgorithms.registerStandardAlgorithms()
        let hostKeyPath: String
        if let bits = options.rsaHostKeyBits {
            hostKeyPath = directory.appendingPathComponent("host_rsa").path
            try run(sshKeygen, ["-q", "-t", "rsa", "-b", String(bits), "-N", "", "-f", hostKeyPath])
        } else {
            hostKeyPath = directory.appendingPathComponent("host_ed25519").path
            try run(sshKeygen, ["-q", "-t", "ed25519", "-N", "", "-f", hostKeyPath])
        }
        let hostKeyLine = try String(contentsOfFile: hostKeyPath + ".pub", encoding: .utf8)
        let hostKey = try NIOSSHPublicKey(openSSHPublicKey: hostKeyLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").prefix(2).joined(separator: " "))
        let rsaUserKeys = try generatedRSAUserKeys(in: directory)

        let keys = [
            NIOSSHPrivateKey(ed25519Key: .init()),
            NIOSSHPrivateKey(p256Key: .init()),
            NIOSSHPrivateKey(p384Key: .init()),
        ]
        let authorizedKeys = (keys.map { String(openSSHPublicKey: $0.publicKey) } + rsaUserKeys.map(\.1))
            .joined(separator: "\n") + "\n"
        let authorizedKeysPath = directory.appendingPathComponent("authorized_keys").path
        try authorizedKeys.write(toFile: authorizedKeysPath, atomically: true, encoding: .utf8)

        var lastError = ""
        for _ in 0..<3 {
            let port = try await freePort()
            let configPath = directory.appendingPathComponent("sshd_config").path
            let extra = options.extraConfig.joined(separator: "\n")
            let config = """
            \(extra)
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
            LogLevel \(options.logLevel)
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
                                      rsaKeys: rsaUserKeys.map(\.0), hostKey: hostKey,
                                      hostKeyPublicPath: hostKeyPath + ".pub", process: process, log: log)
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
        configuration(methods: [.privateKey(key ?? ed25519Key)])
    }

    /// Debug 构建里 DH group16 的模幂一次一到三秒，握手时限给宽。
    func configuration(methods: [SSHAuthenticationMethod], algorithms: SSHAlgorithms = .builtInOnly,
                       hostKeyValidation: SSHHostKeyValidation? = nil) -> SSHClient.Configuration {
        SSHClient.Configuration(
            authentication: SSHAuthentication(username: username, methods: methods),
            hostKeyValidation: hostKeyValidation ?? .trustedKeys([hostKey]),
            connectTimeout: .seconds(5),
            handshakeTimeout: .seconds(60),
            algorithms: algorithms)
    }

    func connect(methods: [SSHAuthenticationMethod], algorithms: SSHAlgorithms = .builtInOnly,
                 hostKeyValidation: SSHHostKeyValidation? = nil) async throws -> SSHClient {
        try await SSHClient.connect(
            host: "127.0.0.1", port: port,
            configuration: configuration(methods: methods, algorithms: algorithms, hostKeyValidation: hostKeyValidation))
    }

    /// sshd 日志里「发出 KEXINIT」的次数（LogLevel DEBUG1）：首次交换 + 每次换钥。
    var keyExchangeCount: Int {
        sshdLog.components(separatedBy: "SSH2_MSG_KEXINIT sent").count - 1
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
