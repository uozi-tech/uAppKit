import Foundation
import USSHCore

/// 一条连接实际用上的一个 SHA-1 时代的旧算法。
public nonisolated struct SSHLegacyAlgorithm: Sendable, Hashable, CustomStringConvertible {
    public enum Role: Sendable, Hashable {
        /// 密钥交换（`diffie-hellman-group14-sha1`）。
        case keyExchange
        /// 主机密钥签名（`ssh-rsa`，SHA-1）。
        case hostKey
        /// 消息认证（`hmac-sha1` / `hmac-sha1-etm@openssh.com`）。
        case mac
        /// RSA 用户私钥的认证签名（`ssh-rsa`，SHA-1）。
        case userAuthentication
    }

    public var role: Role
    public var name: String

    public init(role: Role, name: String) {
        self.role = role
        self.name = name
    }

    public var description: String {
        switch role {
        case .keyExchange: return "kex=\(name)"
        case .hostKey: return "hostkey=\(name)"
        case .mac: return "mac=\(name)"
        case .userAuthentication: return "userauth=\(name)"
        }
    }
}

/// 自动退到旧算法：服务器和我们没有共同的现代算法时，同一跳再连一次，这次在原来的算法后面补上 SHA-1 的旧算法。
///
/// 为什么这样不削弱能连现代服务器的安全性：
/// - 协商取的是「客户端最偏好、服务器也支持」的那个，而补上的旧算法一律排在全部现代算法之后——服务器只要还支持
///   任何一个现代算法，结果就和不补一样；
/// - 双方报的算法列表算进交换哈希，由主机密钥签名。中间人删掉服务器报的现代算法，签名就对不上；所以对一台主机密钥
///   已被信任的服务器，攻击者没法把连接逼到旧算法上；
/// - 于是退级只会发生在真的什么更好的都不支持的服务器上。
///
/// SHA-1 原理上仍然更弱，所以结果不是悄悄发生的：`ConnectedClient.legacyAlgorithmsInUse` 报出用上了哪些，
/// 日志里记一条警告。
///
/// 规则：只在 `SSHClientError.noCommonAlgorithm` 时再试一次；知道卡在哪一类、服务器报了什么时，只在补上的旧算法
/// 对得上服务器的报价时才再试，不知道时盲试一次。超时、没有协商结论的断开、主机密钥被拒、认证失败、取消都不再试。
/// 第一次在密钥交换里就失败了，还没到主机密钥那一步，所以不会问两次信任（另有守卫：第一次问过就不再试）。
/// 跳板机与目标各自判断。
nonisolated enum SSHLegacyFallback {
    /// 在 `algorithms` 后面补上旧算法（已经允许旧算法时返回 nil：没有可退的）。对 `.standard` 补完与
    /// `.legacyCompatible` 的算法一致。
    static func algorithms(addingLegacyTo algorithms: SSHAlgorithms) -> SSHAlgorithms? {
        guard !algorithms.allowsLegacyAlgorithms else { return nil }
        var result = algorithms
        let schemes = Set(result.transportProtectionSchemes.map { ObjectIdentifier($0) })
        result.transportProtectionSchemes += SSHTransportProtections.legacy.filter { !schemes.contains(ObjectIdentifier($0)) }
        result.keyExchangeAlgorithms += SSHDiffieHellmanAlgorithm.legacy.map(\.name)
            .filter { !result.keyExchangeAlgorithms.contains($0) }
        result.hostKeyAlgorithms += SSHRSASignatureAlgorithm.legacy.map(\.name)
            .filter { !result.hostKeyAlgorithms.contains($0) }
        result.allowsLegacyAlgorithms = true
        return result
    }

    /// 第一次以 `failure` 失败后要不要用 `fallback` 再试。
    static func shouldRetry(after failure: SSHAlgorithmNegotiationFailure, with fallback: SSHAlgorithms) -> Bool {
        guard let category = failure.category else { return true }
        let offered = Set(failure.serverOffer)
        return !offered.isDisjoint(with: fallback.names(of: category))
    }

    static let legacyMACNames = Set(SSHTransportProtections.legacy.compactMap { $0.macName })

    /// 传输层（密钥交换 / 主机密钥 / MAC）实际在用的旧算法。读不出协商结果时为空（另看 `negotiated == nil`）。
    static func transportLegacyAlgorithms(_ negotiated: SSHNegotiatedAlgorithms?) -> [SSHLegacyAlgorithm] {
        guard let negotiated else { return [] }
        var result: [SSHLegacyAlgorithm] = []
        if SSHDiffieHellmanAlgorithm(name: negotiated.keyExchange)?.isLegacy == true {
            result.append(.init(role: .keyExchange, name: negotiated.keyExchange))
        }
        if SSHRSASignatureAlgorithm(name: negotiated.hostKey)?.isLegacy == true {
            result.append(.init(role: .hostKey, name: negotiated.hostKey))
        }
        if let mac = negotiated.macInUse, legacyMACNames.contains(mac) {
            result.append(.init(role: .mac, name: mac))
        }
        return result
    }

    /// 协商时用到了旧算法的名字（进程内记录看这个）：比「在用的」多一种情形——加密是 AES-GCM、MAC 并不使用，
    /// 但服务器只报了 `hmac-sha1`，NIOSSH 要名字对上，没有旧算法就协商不出来。读不出协商结果时为 nil（不知道）。
    static func negotiationNeededLegacy(_ negotiated: SSHNegotiatedAlgorithms?) -> Bool? {
        guard let negotiated else { return nil }
        return !transportLegacyAlgorithms(negotiated).isEmpty || legacyMACNames.contains(negotiated.mac)
    }

    /// 这条连接用上的全部旧算法（含 RSA 用户认证的 `ssh-rsa`）。
    static func legacyAlgorithms(_ negotiated: SSHNegotiatedAlgorithms?,
                                 rsaUserAuthentication: SSHRSASignatureAlgorithm?) -> [SSHLegacyAlgorithm] {
        var result = transportLegacyAlgorithms(negotiated)
        if let rsaUserAuthentication, rsaUserAuthentication.isLegacy {
            result.append(.init(role: .userAuthentication, name: rsaUserAuthentication.name))
        }
        return result
    }

    static func legacyAlgorithms(of client: SSHClient) -> [SSHLegacyAlgorithm] {
        legacyAlgorithms(client.negotiatedAlgorithms, rsaUserAuthentication: client.rsaUserAuthenticationAlgorithm)
    }

    /// 一跳连上之后要记的事：进程内记录（知道时才动：用上旧算法就记、没用上就忘；不知道时不动），以及
    /// 要记的警告（用上了旧算法一条；`legacyFallback` 开着却不知道一条）。
    static func outcome(negotiated: SSHNegotiatedAlgorithms?, rsaUserAuthentication: SSHRSASignatureAlgorithm?,
                        host: String, port: Int, legacyFallback: Bool,
                        memory: SSHLegacyEndpointMemory) -> [SSHLogEvent] {
        var events: [SSHLogEvent] = []
        if legacyFallback {
            if let needsLegacy = negotiationNeededLegacy(negotiated) {
                memory.record(host: host, port: port, needsLegacy: needsLegacy)
            } else {
                events.append(SSHLogEvent(
                    level: .warning,
                    message: "无法确定这条 SSH 连接有没有用上旧算法（没读懂服务器的 KEXINIT）",
                    metadata: ["host": host, "port": String(port)]))
            }
        }
        let legacy = legacyAlgorithms(negotiated, rsaUserAuthentication: rsaUserAuthentication)
        if !legacy.isEmpty {
            events.append(SSHLogEvent(
                level: .warning,
                message: "SSH 连接用上了 SHA-1 时代的旧算法（服务器不支持更好的）",
                metadata: [
                    "host": host,
                    "port": String(port),
                    "algorithms": legacy.map(\.description).joined(separator: ","),
                ]))
        }
        return events
    }
}

extension SSHAlgorithms {
    /// 这一套在某类算法里会报给服务器的名字。
    nonisolated func names(of category: SSHAlgorithmNegotiationFailure.Category) -> Set<String> {
        switch category {
        case .keyExchange: return Set(keyExchangeAlgorithms)
        case .hostKey: return Set(hostKeyAlgorithms)
        case .encryption: return Set(transportProtectionSchemes.map { $0.cipherName })
        case .mac: return Set(transportProtectionSchemes.compactMap { $0.macName })
        case .compression: return ["none"]
        }
    }
}

/// 进程内记着哪些 (host, port) 需要旧算法：重连时直接用补上旧算法的那一套，省掉注定失败的那一次。
///
/// 只在内存里：不落盘、不同步、没有界面上的设置。补上的旧算法排在现代算法之后，所以记过的主机以后升级了，照样协商到
/// 现代算法；那时连上之后发现没用上旧算法，就把它忘掉。
nonisolated final class SSHLegacyEndpointMemory: @unchecked Sendable {
    static let shared = SSHLegacyEndpointMemory()

    private struct Endpoint: Hashable {
        var host: String
        var port: Int
    }

    private let lock = NSLock()
    private var endpoints: Set<Endpoint> = []

    func needsLegacy(host: String, port: Int) -> Bool {
        lock.withLock { endpoints.contains(Endpoint(host: host.lowercased(), port: port)) }
    }

    func record(host: String, port: Int, needsLegacy: Bool) {
        let endpoint = Endpoint(host: host.lowercased(), port: port)
        lock.withLock {
            if needsLegacy { endpoints.insert(endpoint) } else { endpoints.remove(endpoint) }
        }
    }
}

/// 记下回调有没有被调过（判断第一次有没有问过信任）。
nonisolated final class SSHApproverWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    var wasCalled: Bool { lock.withLock { called } }

    func wrap(_ approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool)
        -> @Sendable (SSHHostKeyChallenge) async -> Bool {
        { [self] challenge in
            lock.withLock { called = true }
            return await approver(challenge)
        }
    }
}
