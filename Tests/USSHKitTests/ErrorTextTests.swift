import NIOCore
import NIOSSH
import XCTest
@_spi(uTermIntegration) @testable import USSHKit

/// 错误类型 → 文案的对应关系（断言用的是哪条文案键，不比对译文），以及文案目录与源码一致、四种语言齐全。
final class ErrorTextTests: XCTestCase {

    private func localized(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: ModuleBundle.bundle)
    }

    func testClientErrorKeys() {
        let ten = SSHErrorText.formatSeconds(.seconds(10))
        let cases: [(SSHClientError, String)] = [
            (.connectTimeout(.seconds(10)), localized("TCP 连接超时：\(ten) 内未连上")),
            (.handshakeTimeout(.seconds(10)), localized("登录阶段超时：\(ten) 内未完成握手与认证")),
            (.hostKeyValidationTimeout(.seconds(10)), localized("等待确认主机密钥超时（\(ten)）")),
            (.authenticationFailed(.init(remainingMethods: [.publicKey], attemptedMethods: [.publicKey])),
             localized("服务器拒绝了私钥")),
            (.authenticationFailed(.init(remainingMethods: [.password], attemptedMethods: [.password])),
             localized("服务器拒绝了密码")),
            (.authenticationFailed(.init(remainingMethods: [.publicKey], attemptedMethods: [.password, .publicKey])),
             localized("服务器拒绝了提供的凭据")),
            (.authenticationFailed(.init(remainingMethods: [.publicKey, .password], attemptedMethods: [])),
             localized("服务器不接受所提供的认证方式（服务器支持：\("publickey, password")）")),
            (.connectionClosed(.remoteClosed), localized("服务器关闭了连接")),
            (.connectionClosed(.localClose), localized("连接已由本端关闭")),
            (.connectionClosed(.transportError(ChannelError.eof)),
             localized("连接中断：\(SSHErrorText.describe(ChannelError.eof))")),
            (.handshakeFailed(ChannelError.eof), localized("SSH 握手失败：\(SSHErrorText.describe(ChannelError.eof))")),
            (.authenticationDelegateFailed(ChannelError.eof),
             localized("认证过程出错：\(SSHErrorText.describe(ChannelError.eof))")),
            (.connectionClosed(.keepAliveTimeout(unansweredProbes: 3)),
             localized("服务器连续 \(3) 次没有回应保活请求，连接已断开")),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(error.errorDescription, expected, "\(error)")
        }
    }

    /// 建连失败归到 `SSHConnectionError` 的哪个 case（app 按 case 分流：认证失败、主机密钥、其余连不上）。
    func testConnectionErrorCases() throws {
        func map(_ error: any Error) throws -> SSHConnectionError { try SSHClientFactory.connectionError(for: error) }
        guard case .authenticationFailed = try map(SSHClientError.authenticationFailed(
            .init(remainingMethods: [], attemptedMethods: [.password]))) else { return XCTFail() }
        guard case .authenticationFailed = try map(SSHClientError.authenticationDelegateFailed(ChannelError.eof))
        else { return XCTFail("委托认证出错也是认证失败") }
        guard case .hostKeyRejected = try map(SSHClientError.hostKeyValidationTimeout(.seconds(1))) else { return XCTFail() }
        guard case .hostKeyRejected("x") = try map(SSHClientError.hostKeyRejected(SSHConnectionError.hostKeyRejected("x")))
        else { return XCTFail("信任判定自己的拒绝原样交出") }
        for error in [SSHClientError.connectTimeout(.seconds(1)), .handshakeTimeout(.seconds(1)),
                      .connectionClosed(.remoteClosed), .connectFailed(ChannelError.eof)] {
            guard case .connectFailed = try map(error) else { return XCTFail("\(error)") }
        }
        // 握手失败单列（app 据此不重连），文案与连不上相同。
        let handshake = try map(SSHClientError.handshakeFailed(ChannelError.eof))
        guard case .handshakeFailed(let detail) = handshake else { return XCTFail("\(handshake)") }
        XCTAssertEqual(handshake.errorDescription, SSHConnectionError.connectFailed(detail).errorDescription)
        XCTAssertThrowsError(try map(CancellationError())) { XCTAssertTrue($0 is CancellationError) }
    }

    func testChannelErrorKeys() {
        XCTAssertEqual(SSHChannelError.channelClosed.errorDescription, localized("通道已关闭"))
        XCTAssertEqual(SSHChannelError.channelFailed(ChannelError.eof).errorDescription,
                       localized("通道出错：\(SSHErrorText.describe(ChannelError.eof))"))
        XCTAssertEqual(SSHChannelError.requestRejected(.subsystem("sftp")).errorDescription,
                       localized("服务器拒绝了通道请求（\("subsystem sftp")）"))
        XCTAssertEqual(SSHChannelError.globalRequestRejected(.tcpipForward(host: "0.0.0.0", port: 8080)).errorDescription,
                       localized("服务器拒绝了端口转发请求（\("0.0.0.0"):\(String(8080))）"))
        XCTAssertEqual(SSHChannelError.connectionClosed(.remoteClosed).errorDescription,
                       localized("SSH 连接已断开：\(localized("服务器关闭了连接"))"))
    }

    func testSFTPErrorKeys() {
        XCTAssertEqual(SFTPError.status(code: .noSuchFile, message: "No such file", languageTag: "").errorDescription,
                       localized("文件或路径不存在"))
        XCTAssertEqual(SFTPError.status(code: .permissionDenied, message: "", languageTag: "").errorDescription,
                       localized("权限不足"))
        XCTAssertEqual(SFTPError.status(code: .failure, message: "Is a directory", languageTag: "").errorDescription,
                       localized("服务器操作失败：\("Is a directory")"), "FAILURE 的具体原因在服务端原话里")
        XCTAssertEqual(SFTPError.status(code: .failure, message: " ", languageTag: "").errorDescription,
                       localized("服务器操作失败"))
        XCTAssertEqual(SFTPError.status(code: SFTPStatusCode(99), message: "odd", languageTag: "").errorDescription,
                       localized("SFTP 错误（代码 \(String(99))）：\("odd")"))
        XCTAssertEqual(SFTPError.connectionClosed.errorDescription, localized("SFTP 通道已断开"))
        XCTAssertEqual(SFTPError.shortRead(expected: 100, actual: 40).errorDescription,
                       localized("文件在读取过程中变短了（应有 \(100) 字节，只读到 \(40) 字节）"))
        XCTAssertEqual(SFTPError.offsetOutOfRange.errorDescription, localized("读写的位置超出了范围"))
        XCTAssertEqual(SFTPError.requestTooLarge(length: 70_000, limit: 32_768).errorDescription,
                       localized("SFTP 请求过大（\(70_000) 字节，上限 \(32_768) 字节）"))
    }

    func testCommandAndKeyErrorKeys() {
        XCTAssertEqual(SSHCommandError.nonZeroExit(.exited(2), output: ByteBuffer()).errorDescription,
                       localized("命令以状态 \(String(2)) 退出"))
        XCTAssertEqual(SSHCommandError.nonZeroExit(.signaled(.init(name: "KILL", coreDumped: false, message: "")),
                                                   output: ByteBuffer()).errorDescription,
                       localized("命令被信号 \("KILL") 终止"))
        XCTAssertEqual(SSHCommandError.outputTooLarge(limit: 64_000).errorDescription,
                       localized("命令输出超过上限（\(64_000) 字节）"))
        XCTAssertEqual(SSHRSAError.unsupportedModulusSize(bits: 512).errorDescription,
                       localized("RSA 密钥长度 \(String(512)) 位不受支持（支持 \(String(1024))–\(String(8192)) 位）"))
    }

    /// 没有共同算法：按类别与服务器的报价分三种说法（断言文案键，不比对译文）。
    func testNoCommonAlgorithmKeys() {
        func text(_ category: SSHAlgorithmNegotiationFailure.Category?, _ offer: [String]) -> String? {
            SSHClientError.noCommonAlgorithm(.init(category: category, clientOffer: ["x"], serverOffer: offer)).errorDescription
        }
        func handshake(_ detail: String) -> String { localized("SSH 握手失败：\(detail)") }
        let hostKey = localized("主机密钥")
        let keyExchange = localized("密钥交换")
        let encryption = localized("加密")
        let mac = localized("消息认证（MAC）")
        XCTAssertEqual(text(nil, []), handshake(localized("与服务器没有共同支持的算法")))
        XCTAssertEqual(text(.hostKey, ["rsa-sha2-512", "rsa-sha2-256"]),
                       handshake(localized("这次连接没有启用服务器提供的任何\(hostKey)算法（服务器提供：\("rsa-sha2-512, rsa-sha2-256")）")))
        XCTAssertEqual(text(.hostKey, ["ssh-rsa"]),
                       handshake(localized("服务器只提供 SHA-1 时代的旧\(hostKey)算法（服务器提供：\("ssh-rsa")）。这类算法安全性较低，通常只有很旧的设备还在用；这次连接没有启用兼容旧设备的算法。")))
        XCTAssertEqual(text(.keyExchange, ["diffie-hellman-group14-sha1"]),
                       handshake(localized("服务器只提供 SHA-1 时代的旧\(keyExchange)算法（服务器提供：\("diffie-hellman-group14-sha1")）。这类算法安全性较低，通常只有很旧的设备还在用；这次连接没有启用兼容旧设备的算法。")))
        XCTAssertEqual(text(.encryption, ["aes128-cbc"]),
                       handshake(localized("本应用不支持服务器提供的任何\(encryption)算法（服务器提供：\("aes128-cbc")）")))
        XCTAssertEqual(text(.mac, []),
                       handshake(localized("本应用不支持服务器提供的任何\(mac)算法（服务器提供：\(localized("无"))）")))
        // 归到 `.handshakeFailed`（不是网络断开，重试也不会好；显示同 `.connectFailed`）。
        let mapped = try? SSHClientFactory.connectionError(for: SSHClientError.noCommonAlgorithm(.init(
            category: .hostKey, clientOffer: [], serverOffer: ["ssh-rsa"])))
        guard case .handshakeFailed = mapped else { return XCTFail("\(String(describing: mapped))") }
    }

    /// 英文资源确实带上了新文案（找不到时界面只剩中文原文）。
    func testNewMessagesAreTranslated() throws {
        let english = try XCTUnwrap(ModuleBundle.bundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        for key in ["服务器拒绝了私钥", "通道已关闭", "文件或路径不存在", "登录阶段超时：%@ 内未完成握手与认证"] {
            let value = english.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertNotEqual(value, key, key)
        }
    }

    // MARK: - 文案目录

    /// 源码里每一条 `String(localized: "…")` 都在 `Localizable.xcstrings` 里，目录里没有用不上的条目，
    /// 每条都有 en / zh-Hant / ja / ko 的译文，且占位符个数一致。
    func testCatalogMatchesSourcesAndIsFullyTranslated() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources/USSHKit")
        let catalogURL = sources.appendingPathComponent("Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as! [String: Any]
        let strings = catalog["strings"] as! [String: [String: Any]]

        var used = Set<String>()
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            for literal in Self.localizedLiterals(in: try String(contentsOf: url, encoding: .utf8)) {
                used.insert(Self.normalize(literal))
            }
        }
        XCTAssertFalse(used.isEmpty)

        let catalogKeys = Dictionary(strings.keys.map { (Self.normalize($0), $0) }, uniquingKeysWith: { a, _ in a })
        for key in used.sorted() {
            XCTAssertNotNil(catalogKeys[key], "源码里的文案没进目录：\(key)")
        }
        for (normalized, key) in catalogKeys where !used.contains(normalized) {
            XCTFail("目录里的条目源码里已经不用了：\(key)")
        }

        for (key, entry) in strings {
            let placeholders = Self.placeholderCount(key)
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in ["en", "zh-Hant", "ja", "ko"] {
                let values = Self.values(in: localizations[language])
                XCTAssertFalse(values.isEmpty, "\(key) 缺 \(language)")
                for value in values {
                    XCTAssertEqual(Self.placeholderCount(value), placeholders, "\(key) 的 \(language) 占位符个数不对：\(value)")
                }
            }
        }
    }

    /// 取 `String(localized: "…"` 的字面量（`\(…)` 插值原样保留，里面可以再有括号和引号）。
    static func localizedLiterals(in source: String) -> [String] {
        let marker = Array("String(localized: \"")
        let chars = Array(source)
        var results: [String] = []
        var index = 0
        while index + marker.count <= chars.count {
            guard Array(chars[index..<index + marker.count]) == marker else { index += 1; continue }
            var i = index + marker.count
            var literal = ""
            while i < chars.count, chars[i] != "\"" {
                if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
                    var depth = 1
                    literal.append("\\(")
                    i += 2
                    while i < chars.count, depth > 0 {
                        if chars[i] == "(" { depth += 1 }
                        if chars[i] == ")" { depth -= 1 }
                        literal.append(chars[i])
                        i += 1
                    }
                    continue
                }
                if chars[i] == "\\", i + 1 < chars.count {
                    literal.append(chars[i])
                    literal.append(chars[i + 1])
                    i += 2
                    continue
                }
                literal.append(chars[i])
                i += 1
            }
            results.append(literal)
            index = i + 1
        }
        return results
    }

    /// 插值与格式占位符都换成同一个记号，两边才能比。
    static func normalize(_ key: String) -> String {
        var result = ""
        var chars = Array(key)[...]
        while let c = chars.first {
            if c == "\\", chars.dropFirst().first == "(" {
                var depth = 0
                while let d = chars.first {
                    chars = chars.dropFirst()
                    if d == "(" { depth += 1 }
                    if d == ")" { depth -= 1; if depth == 0 { break } }
                }
                result.append("\u{1}")
                continue
            }
            result.append(c)
            chars = chars.dropFirst()
        }
        return result
            .replacingOccurrences(of: "%lld", with: "\u{1}")
            .replacingOccurrences(of: "%@", with: "\u{1}")
    }

    /// `%@` / `%lld`，含带位置的 `%1$@` / `%2$lld`。
    static func placeholderCount(_ text: String) -> Int {
        let pattern = try! NSRegularExpression(pattern: #"%(\d+\$)?(@|lld)"#)
        return pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// 一个语言的全部取值（含复数变体）。
    static func values(in localization: Any?) -> [String] {
        guard let localization = localization as? [String: Any] else { return [] }
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            return [value]
        }
        guard let variations = localization["variations"] as? [String: Any] else { return [] }
        return variations.values.flatMap { kind -> [String] in
            (kind as? [String: Any] ?? [:]).values.flatMap { values(in: $0) }
        }
    }
}
