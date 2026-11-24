import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import USSHCore

// USSHCore 不带面向用户的文字（错误只有类型与载荷），文案归 USSHKit：这里给它的错误类型补上
// `LocalizedError`，于是 app 里 `error.localizedDescription`（以及据此取文案的 `FriendlyError`、alert）
// 直接拿到本地化的句子，不会再是「未能完成操作（USSHCore.SFTPError 错误 0）」。
// 判断错误一律看类型与 case，不看这里的文字。

/// 把底层错误翻成能定位问题的文案。
nonisolated enum SSHErrorText {

    /// 任意错误的文案。
    ///
    /// 纯 Swift 值类型错误（如 `NIOCore.ChannelError`）没有 `LocalizedError`，其 `localizedDescription` 走
    /// NSError 桥接，只会给出「未能完成操作。（NIOCore.ChannelError 错误 0。）」—— 那个数字是 case 的序号，
    /// 完全无法定位。这类错误改用其自身的 `description` 并附上类型名。
    static func describe(_ error: any Error) -> String {
        if let connectionError = error as? NIOConnectionError {
            // 同样是无 LocalizedError 的值类型（struct → 恒为「错误 1」）。取最后一次尝试的
            // 底层 IOError（含 errno 与 strerror），再带上目标地址。
            let target = "\(connectionError.host):\(connectionError.port)"
            if let last = connectionError.connectionErrors.last {
                return String(localized: "无法连接 \(target)：\(describe(last.error))", bundle: ModuleBundle.bundle)
            }
            if let dns = connectionError.dnsAError ?? connectionError.dnsAAAAError {
                return String(localized: "无法解析 \(connectionError.host)：\(describe(dns))", bundle: ModuleBundle.bundle)
            }
            return String(localized: "无法连接 \(target)（NIOPosix.NIOConnectionError）", bundle: ModuleBundle.bundle)
        }
        if let ioError = error as? IOError {
            // IOError 自带 description（"<reason>: <strerror> (errno: N)"），比桥接文案有用。
            return String(describing: ioError)
        }
        if let channelError = error as? ChannelError {
            return "\(channelError)（NIOCore.ChannelError）"
        }
        if let sshError = error as? NIOSSHError {
            // 有的带对端的原话（协议错误里的 DEBUG 文本、拒绝开通道的说明）。
            return SSHPeerText.isolated(String(describing: sshError))
        }
        if error is LocalizedError || type(of: error) is NSError.Type {
            let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !localized.isEmpty { return localized }
        }
        // 不认识的错误类型：描述里可能有对端的文字。
        let described = SSHPeerText.sanitize(String(describing: error))
        let typeName = String(reflecting: type(of: error))
        if described.isEmpty || described == typeName {
            return typeName
        }
        let isolated = "\u{2068}\(described)\u{2069}"
        return described.contains(typeName) ? isolated : "\(isolated)（\(typeName)）"
    }

    /// 连接为什么断了。
    static func describe(_ reason: SSHDisconnectReason) -> String {
        switch reason {
        case .localClose:
            return String(localized: "连接已由本端关闭", bundle: ModuleBundle.bundle)
        case .remoteClosed:
            return String(localized: "服务器关闭了连接", bundle: ModuleBundle.bundle)
        case .transportError(let error):
            return String(localized: "连接中断：\(describe(error))", bundle: ModuleBundle.bundle)
        case .keepAliveTimeout(let unanswered):
            return String(localized: "服务器连续 \(unanswered) 次没有回应保活请求，连接已断开", bundle: ModuleBundle.bundle)
        }
    }

    /// CHANNEL_OPEN_FAILURE 按原因码说（RFC 4254 §5.1）：服务器不许开这类通道、服务器连不上目标，用户要分得清。
    static func describe(_ failure: SSHChannelOpenFailure) -> String {
        switch failure.reason {
        case .administrativelyProhibited:
            return String(localized: "服务器禁止打开这类通道（例如关闭了端口转发）", bundle: ModuleBundle.bundle)
        case .connectFailed:
            return String(localized: "服务器连不上目标（连接被拒绝或地址不可达）", bundle: ModuleBundle.bundle)
        case .unknownChannelType:
            return String(localized: "服务器不支持这类通道", bundle: ModuleBundle.bundle)
        case .resourceShortage:
            return String(localized: "服务器资源不足，暂时打不开新通道（例如超过了 MaxSessions）", bundle: ModuleBundle.bundle)
        case .other:
            let code = String(failure.reasonCode)
            let detail = SSHPeerText.sanitize(failure.description)
            if detail.isEmpty {
                return String(localized: "服务器拒绝打开通道（原因码 \(code)）", bundle: ModuleBundle.bundle)
            }
            return String(localized: "服务器拒绝打开通道（原因码 \(code)）：\(SSHPeerText.isolated(detail))", bundle: ModuleBundle.bundle)
        }
    }

    /// 双方没有共同算法：说是哪一类、服务器报了什么。
    ///
    /// 三种情况分开说：服务器报的算法在 `.standard` 里（这次连接用的算法集比默认的还窄）；只在
    /// `.legacyCompatible` 里（SHA-1 时代的旧算法，很旧的设备才只剩这些——默认会自动退到它们，看到这句说明这次
    /// 连接关掉了自动退级）；本应用根本不支持（例如 CBC 加密、`hmac-md5`），换算法集也没用。
    /// app 没有按主机打开旧算法的设置，所以文案只陈述「这次连接没有启用兼容旧设备的算法」，不指向某个设置项。
    static func describe(_ failure: SSHAlgorithmNegotiationFailure) -> String {
        guard let category = failure.category else {
            return String(localized: "与服务器没有共同支持的算法", bundle: ModuleBundle.bundle)
        }
        let name = describe(category)
        let offer = failure.serverOffer.isEmpty
            ? String(localized: "无", bundle: ModuleBundle.bundle, comment: "服务器在这一类里什么算法都没报")
            : SSHPeerText.isolated(failure.serverOffer.joined(separator: ", "))
        let server = Set(failure.serverOffer)
        if !server.isDisjoint(with: SSHAlgorithms.standard.names(of: category)) {
            return String(localized: "这次连接没有启用服务器提供的任何\(name)算法（服务器提供：\(offer)）", bundle: ModuleBundle.bundle)
        }
        if !server.isDisjoint(with: SSHAlgorithms.legacyCompatible.names(of: category)) {
            return String(localized: "服务器只提供 SHA-1 时代的旧\(name)算法（服务器提供：\(offer)）。这类算法安全性较低，通常只有很旧的设备还在用；这次连接没有启用兼容旧设备的算法。", bundle: ModuleBundle.bundle)
        }
        return String(localized: "本应用不支持服务器提供的任何\(name)算法（服务器提供：\(offer)）", bundle: ModuleBundle.bundle)
    }

    static func describe(_ category: SSHAlgorithmNegotiationFailure.Category) -> String {
        switch category {
        case .keyExchange: return String(localized: "密钥交换", bundle: ModuleBundle.bundle, comment: "算法类别，嵌在「…的任何%@算法」里")
        case .hostKey: return String(localized: "主机密钥", bundle: ModuleBundle.bundle, comment: "算法类别，嵌在「…的任何%@算法」里")
        case .encryption: return String(localized: "加密", bundle: ModuleBundle.bundle, comment: "算法类别，嵌在「…的任何%@算法」里")
        case .mac: return String(localized: "消息认证（MAC）", bundle: ModuleBundle.bundle, comment: "算法类别，嵌在「…的任何%@算法」里")
        case .compression: return String(localized: "压缩", bundle: ModuleBundle.bundle, comment: "算法类别，嵌在「…的任何%@算法」里")
        }
    }

    /// 认证失败的原因：按实际发出过的方式说；什么都没发出过、或发出过的方式服务器根本不收，
    /// 就列出服务器接受的方式。
    static func describe(_ failure: SSHAuthenticationFailure) -> String {
        if !failure.partiallyAcceptedMethods.isEmpty {
            // 凭据没被拒：这一步通过了，服务器还要别的（口令、一次性验证码……），配置里没有能用的。
            var names: [String] = []
            for kind in failure.partiallyAcceptedMethods {
                let name = describe(kind)
                if !names.contains(name) { names.append(name) }
            }
            let accepted = names.joined(separator: String(localized: "、", bundle: ModuleBundle.bundle, comment: "并列项之间的分隔符"))
            return String(localized: "服务器已接受\(accepted)，但还要求另一种认证（服务器支持：\(methodNames(failure.remainingMethods))），没有配置可用的方式", bundle: ModuleBundle.bundle)
        }
        let attempted = Set(failure.attemptedMethods)
        let acceptedByServer = attempted.contains { kind in
            switch kind {
            case .password: return failure.remainingMethods.contains(.password)
            case .publicKey: return failure.remainingMethods.contains(.publicKey)
            case .delegate: return true
            }
        }
        if attempted.isEmpty || !acceptedByServer {
            return String(localized: "服务器不接受所提供的认证方式（服务器支持：\(methodNames(failure.remainingMethods))）", bundle: ModuleBundle.bundle)
        }
        if attempted == [.publicKey] {
            return String(localized: "服务器拒绝了私钥", bundle: ModuleBundle.bundle)
        }
        if attempted == [.password] {
            return String(localized: "服务器拒绝了密码", bundle: ModuleBundle.bundle)
        }
        return String(localized: "服务器拒绝了提供的凭据", bundle: ModuleBundle.bundle)
    }

    /// 认证方式的叫法（嵌在「服务器已接受…」里）。
    static func describe(_ kind: SSHAuthenticationMethod.Kind) -> String {
        switch kind {
        case .password: return String(localized: "密码", bundle: ModuleBundle.bundle, comment: "认证方式，嵌在「服务器已接受%@」里")
        case .publicKey: return String(localized: "私钥", bundle: ModuleBundle.bundle, comment: "认证方式，嵌在「服务器已接受%@」里")
        case .delegate: return String(localized: "前一步认证", bundle: ModuleBundle.bundle, comment: "认证方式，嵌在「服务器已接受%@」里")
        }
    }

    /// RFC 4252 的方式名，协议里的写法，不翻译。
    static func methodNames(_ methods: NIOSSHAvailableUserAuthenticationMethods) -> String {
        var names: [String] = []
        if methods.contains(.publicKey) { names.append("publickey") }
        if methods.contains(.password) { names.append("password") }
        if methods.contains(.hostBased) { names.append("hostbased") }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    static func formatSeconds(_ duration: Duration) -> String {
        let parts = duration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        if seconds == seconds.rounded(), seconds < Double(Int.max) {
            let whole = Int(seconds)
            return String(localized: "\(whole) 秒", bundle: ModuleBundle.bundle)
        }
        let text = String(format: "%.1f", seconds)
        return String(localized: "\(text) 秒", bundle: ModuleBundle.bundle, comment: "带一位小数的秒数")
    }
}

// MARK: - USSHCore 错误的文案

extension SSHClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectTimeout(let timeout):
            return String(localized: "TCP 连接超时：\(SSHErrorText.formatSeconds(timeout)) 内未连上", bundle: ModuleBundle.bundle)
        case .connectFailed(let error):
            return SSHErrorText.describe(error)
        case .handshakeTimeout(let timeout):
            return String(localized: "登录阶段超时：\(SSHErrorText.formatSeconds(timeout)) 内未完成握手与认证", bundle: ModuleBundle.bundle)
        case .hostKeyValidationTimeout(let timeout):
            return String(localized: "等待确认主机密钥超时（\(SSHErrorText.formatSeconds(timeout))）", bundle: ModuleBundle.bundle)
        case .hostKeyRejected(let error):
            return SSHErrorText.describe(error)
        case .authenticationFailed(let failure):
            return SSHErrorText.describe(failure)
        case .authenticationDelegateFailed(let error):
            return String(localized: "认证过程出错：\(SSHErrorText.describe(error))", bundle: ModuleBundle.bundle)
        case .handshakeFailed(let error):
            return String(localized: "SSH 握手失败：\(SSHErrorText.describe(error))", bundle: ModuleBundle.bundle)
        case .noCommonAlgorithm(let failure):
            return String(localized: "SSH 握手失败：\(SSHErrorText.describe(failure))", bundle: ModuleBundle.bundle)
        case .connectionClosed(let reason):
            return SSHErrorText.describe(reason)
        }
    }
}

extension SSHDisconnectReason {
    /// 给人看的断开原因（「服务器连续 3 次没有回应保活请求，连接已断开」）。判断原因看 case，不看这段文字。
    public var userDescription: String { SSHErrorText.describe(self) }
}

extension SSHChannelError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .openRejected(let failure):
            return SSHErrorText.describe(failure)
        case .channelFailed(let error):
            return String(localized: "通道出错：\(SSHErrorText.describe(error))", bundle: ModuleBundle.bundle)
        case .requestRejected(let kind):
            return String(localized: "服务器拒绝了通道请求（\(Self.name(of: kind))）", bundle: ModuleBundle.bundle)
        case .globalRequestRejected(.tcpipForward(let host, let port)):
            return String(localized: "服务器拒绝了端口转发请求（\(host):\(String(port))）", bundle: ModuleBundle.bundle)
        case .globalRequestRejected(.cancelTcpipForward(let host, let port)):
            return String(localized: "服务器拒绝撤销端口转发（\(host):\(String(port))）", bundle: ModuleBundle.bundle)
        case .channelClosed:
            return String(localized: "通道已关闭", bundle: ModuleBundle.bundle)
        case .connectionClosed(let reason):
            return String(localized: "SSH 连接已断开：\(SSHErrorText.describe(reason))", bundle: ModuleBundle.bundle)
        case .timeout(let timeout):
            return String(localized: "等待服务器响应超时（\(SSHErrorText.formatSeconds(timeout))）", bundle: ModuleBundle.bundle)
        }
    }

    /// RFC 4254 里请求的名字，不翻译。
    private static func name(of kind: SSHChannelRequestKind) -> String {
        switch kind {
        case .pseudoTerminal: return "pty-req"
        case .shell: return "shell"
        case .exec: return "exec"
        case .subsystem(let name): return "subsystem \(name)"
        case .environment(let name): return "env \(name)"
        case .windowChange: return "window-change"
        case .signal(let name): return "signal \(name)"
        }
    }
}

extension SFTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .status(let code, let message, _):
            return Self.describe(code, message: SSHPeerText.sanitize(message))
        case .connectionClosed:
            return String(localized: "SFTP 通道已断开", bundle: ModuleBundle.bundle)
        case .invalidResponse(let detail):
            return String(localized: "SFTP 服务器的回应不符合协议：\(SSHPeerText.isolated(detail))", bundle: ModuleBundle.bundle)
        case .unsupportedVersion(let version):
            return String(localized: "SFTP 服务器的协议版本 \(String(version)) 不受支持", bundle: ModuleBundle.bundle)
        case .requestTooLarge(let length, let limit):
            return String(localized: "SFTP 请求过大（\(length) 字节，上限 \(limit) 字节）", bundle: ModuleBundle.bundle)
        case .extensionUnsupported(let name):
            return String(localized: "SFTP 服务器不支持 \(SSHPeerText.isolated(name))", bundle: ModuleBundle.bundle)
        case .handleClosed:
            return String(localized: "文件句柄已关闭", bundle: ModuleBundle.bundle)
        case .limitExceeded(let maximumBytes):
            return String(localized: "读取的内容超过上限（\(maximumBytes) 字节）", bundle: ModuleBundle.bundle)
        case .shortRead(let expected, let actual):
            return String(localized: "文件在读取过程中变短了（应有 \(expected) 字节，只读到 \(actual) 字节）", bundle: ModuleBundle.bundle)
        case .offsetOutOfRange:
            return String(localized: "读写的位置超出了范围", bundle: ModuleBundle.bundle)
        }
    }

    private static func describe(_ code: SFTPStatusCode, message: String) -> String {
        switch code {
        case .eof:
            return String(localized: "已到文件末尾", bundle: ModuleBundle.bundle)
        case .noSuchFile, .noSuchPath:
            return String(localized: "文件或路径不存在", bundle: ModuleBundle.bundle)
        case .permissionDenied, .writeProtect:
            return String(localized: "权限不足", bundle: ModuleBundle.bundle)
        case .operationUnsupported:
            return String(localized: "服务器不支持该操作", bundle: ModuleBundle.bundle)
        case .fileAlreadyExists:
            return String(localized: "目标已存在", bundle: ModuleBundle.bundle)
        case .noSpaceOnFilesystem, .quotaExceeded:
            return String(localized: "服务器磁盘空间不足", bundle: ModuleBundle.bundle)
        case .directoryNotEmpty:
            return String(localized: "目录不为空", bundle: ModuleBundle.bundle)
        case .notADirectory:
            return String(localized: "路径中包含非目录项", bundle: ModuleBundle.bundle)
        case .fileIsADirectory:
            return String(localized: "目标是一个目录", bundle: ModuleBundle.bundle)
        case .failure:
            // SSH_FX_FAILURE 是 v3 的兜底码，具体原因只在服务端的原话里。
            if message.isEmpty {
                return String(localized: "服务器操作失败", bundle: ModuleBundle.bundle)
            }
            return String(localized: "服务器操作失败：\(SSHPeerText.isolated(message))", bundle: ModuleBundle.bundle)
        default:
            let number = String(code.rawValue)
            if message.isEmpty {
                return String(localized: "SFTP 错误（代码 \(number)）", bundle: ModuleBundle.bundle)
            }
            return String(localized: "SFTP 错误（代码 \(number)）：\(SSHPeerText.isolated(message))", bundle: ModuleBundle.bundle)
        }
    }
}

extension SSHCommandError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nonZeroExit(.exited(let status), _):
            return String(localized: "命令以状态 \(String(status)) 退出", bundle: ModuleBundle.bundle)
        case .nonZeroExit(.signaled(let signal), _):
            return String(localized: "命令被信号 \(SSHPeerText.isolated(signal.name)) 终止", bundle: ModuleBundle.bundle)
        case .nonZeroExit(.unknown, _):
            return String(localized: "命令结束时没有报告退出状态", bundle: ModuleBundle.bundle)
        case .outputTooLarge(let limit):
            return String(localized: "命令输出超过上限（\(limit) 字节）", bundle: ModuleBundle.bundle)
        }
    }
}

extension SSHRSAError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedModulusSize(let bits):
            let minimum = String(SSHRSAPublicKey.minimumModulusBits)
            let maximum = String(SSHRSAPublicKey.maximumModulusBits)
            return String(localized: "RSA 密钥长度 \(String(bits)) 位不受支持（支持 \(minimum)–\(maximum) 位）", bundle: ModuleBundle.bundle)
        case .invalidPublicKey, .unexpectedKeyType:
            return String(localized: "RSA 公钥分量不合法", bundle: ModuleBundle.bundle)
        case .invalidPrivateKey:
            return String(localized: "RSA 私钥分量不合法或彼此不一致", bundle: ModuleBundle.bundle)
        case .unknownSignatureAlgorithm, .invalidSignatureLength, .signingFailed:
            return String(localized: "RSA 签名失败", bundle: ModuleBundle.bundle)
        }
    }
}
