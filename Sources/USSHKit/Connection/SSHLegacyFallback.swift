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
/// 安全上能保证什么、不能保证什么（`LegacyFallbackTamperingTests` 逐条验证）：
/// - **能被中间人触发的只有那一次再试。** 第一次连接的 KEXINIT 是明文、没有认证：中间人把服务器的报价换成只剩
///   `ssh-rsa` / group14-sha1，客户端就判成「没有共同算法」、补上旧算法再连一次。代价只是多一次连接。
/// - **再试的那一次不会因此用上旧算法。** 协商取「客户端最偏好、服务器也支持」的那个，补上的旧算法一律排在全部现代算法
///   之后：真正的服务器只要还支持任何一个现代算法，第二次照样协商到现代算法。中间人要让第二次用 SHA-1，就得再改第二次的
///   KEXINIT；而双方报的算法列表算进交换哈希、由主机密钥签名，改了任何一边，两端的交换哈希就不同，主机签名验不过、
///   连接失败——结果是连不上，不是悄悄降级。
/// - **这条保证依赖 SHA-1 的抗碰撞性。** 服务器本身也还支持 `ssh-rsa` 时，中间人可以把两边都改成只剩 `ssh-rsa`、让服务器
///   用 SHA-1 签名；要让这个签名在客户端验得过，被签的两份东西（两端各自算的交换哈希，输入里有客户端这次随机生成的
///   cookie）经 SHA-1 之后必须相同，而且必须在握手超时之内现场算出来——已知最好的 SHA-1 选择前缀碰撞也要约 2^63 次运算，
///   密钥交换本身是 SHA-256 的时候更难（两个 32 字节的哈希值之间找 SHA-1 碰撞，只能硬算约 2^80 次）。服务器不支持
///   `ssh-rsa`（OpenSSH 8.8 起的默认）时连这个前提都没有。
/// - **记录只在认证成功、而且协商结果里真的有旧算法之后才写**（`outcome`）：一次失败的、被篡改的握手什么也不留下。
/// - **主机密钥认不出「同一把钥匙的另一台机器」。** 好几台机器共用一把主机密钥（克隆的镜像）时，中间人本来就能把客户端
///   转去另一台；那台只支持 SHA-1 时，自动退级让这次转向也能连上（并记下「需要旧算法」，下次第一次就补上——补上的仍排在
///   现代算法之后，对真的服务器没有影响）。这不是对真正那台服务器的降级，是共用主机密钥的固有问题。
///
/// SHA-1 原理上仍然更弱，所以结果不是悄悄发生的：`ConnectedClient.legacyAlgorithmsInUse` 报出用上了哪些，
/// 日志里记一条警告。一台主机密钥已被信任、以前从没需要过旧算法的服务器突然需要了，USSHKit 现在不会拦下来（进程内的
/// 记录不落盘，它不知道「以前」）；要拦，app 得把「这台需要旧算法」记在自己的主机记录里，见迁移说明。
///
/// RSA **用户**签名的 SHA-1（`ssh-rsa`）回退是另一回事，第一次连接就开着（`makeConfiguration` 把
/// `allowsSHA1RSAUserAuthenticationFallback` 设成 `legacyFallback`），为的是 OpenSSH 6.5–7.1 这类主机密钥与密钥交换都是现代的、
/// 却只认 `ssh-rsa` 用户签名、也不发 `server-sig-algs` 的服务器——它们第一次就连得上，没有第二次可以等。拿得到这个签名的
/// 只有认证所在的那条传输的对端：主机密钥已经按 app 的策略验过（`.insecureAcceptAll` 或用户认了一把陌生钥匙时就是那台
/// 机器），而且它没宣告 `server-sig-algs`（或只列了 `ssh-rsa`）、先后拒绝了 `rsa-sha2-512` 与 `rsa-sha2-256`。
/// `server-sig-algs` 在 NEWKEYS 之后加密送来，线路上的中间人删不掉；签的内容以这条会话的会话标识开头，换到别的会话用
/// 不了（除非两份签名内容 SHA-1 碰撞，同样得现场算）。对端已经是认证对象本身，它从 SHA-1 签名里得不到 SHA-2 签名给不了
/// 的东西，所以没再收紧：收紧（例如只在再试的那次打开）会让上面那类服务器连不上。
///
/// 规则（`legacyFallback: true` 的含义）：遇到类型化的「没有共同算法」（`SSHClientError.noCommonAlgorithm`）时，
/// 用「配置的算法 + `.standard` 的现代算法 + 旧算法」（`retryAlgorithms`）再试一次。知道卡在哪一类、服务器报了什么时，
/// 只在服务器这一类的报价与扩展出来的那些名字有交集时才试；不知道时盲试一次。超时、没有协商结论的断开、主机密钥被拒、
/// 认证失败、取消都不再试。把自己的 `SSHAlgorithms` 当严格策略的调用方（例如明确只要 `.builtInOnly`）传 `legacyFallback: false`。
/// 第一次在密钥交换里就失败了，还没到主机密钥那一步，所以不会问两次信任（另有守卫：第一次问过就不再试）。
/// 跳板机与目标各自判断。
nonisolated enum SSHLegacyFallback {
    /// 再试一次时用的算法：
    /// 1. 调用方配置的算法里的现代算法，保持原来的顺序；
    /// 2. `.standard` 里有、配置里没有的现代算法（例如 `.builtInOnly` 再试时也带上 group14-sha256、
    ///    AES-CTR + hmac-sha2，服务器同时有 SHA-2 与 SHA-1 的选项时协商到 SHA-2 的那个）；
    /// 3. 最后才是旧算法：配置里本来就列着的（挪到所有现代算法后面——列着不等于启用，以前它们会原地被打开，
    ///    排在现代算法前面），再补上没列的。
    ///
    /// 已经允许旧算法时返回 nil：没有可退的。对 `.standard` 与 `.legacyCompatible` 一致。
    static func retryAlgorithms(for configured: SSHAlgorithms) -> SSHAlgorithms? {
        guard !configured.allowsLegacyAlgorithms else { return nil }
        let standard = SSHAlgorithms.standard
        func ordered(_ configured: [String], standard: [String], legacy: [String], isLegacy: (String) -> Bool) -> [String] {
            let modern = configured.filter { !isLegacy($0) }
            let additions = standard.filter { !isLegacy($0) && !modern.contains($0) }
            let configuredLegacy = configured.filter(isLegacy)
            let legacyAdditions = legacy.filter { !configuredLegacy.contains($0) }
            return modern + additions + configuredLegacy + legacyAdditions
        }
        var result = configured
        result.keyExchangeAlgorithms = ordered(
            configured.keyExchangeAlgorithms, standard: standard.keyExchangeAlgorithms,
            legacy: SSHDiffieHellmanAlgorithm.legacy.map(\.name),
            isLegacy: { SSHDiffieHellmanAlgorithm(name: $0)?.isLegacy == true })
        result.hostKeyAlgorithms = ordered(
            configured.hostKeyAlgorithms, standard: standard.hostKeyAlgorithms,
            legacy: SSHRSASignatureAlgorithm.legacy.map(\.name),
            isLegacy: { SSHRSASignatureAlgorithm(name: $0)?.isLegacy == true })
        let legacySchemes = Set(SSHTransportProtections.legacy.map { ObjectIdentifier($0) })
        func isLegacy(_ scheme: SSHTransportProtections.Scheme) -> Bool { legacySchemes.contains(ObjectIdentifier(scheme)) }
        func contains(_ list: [SSHTransportProtections.Scheme], _ scheme: SSHTransportProtections.Scheme) -> Bool {
            list.contains { ObjectIdentifier($0) == ObjectIdentifier(scheme) }
        }
        let modern = configured.transportProtectionSchemes.filter { !isLegacy($0) }
        let additions = standard.transportProtectionSchemes.filter { !isLegacy($0) && !contains(modern, $0) }
        let configuredLegacy = configured.transportProtectionSchemes.filter(isLegacy)
        let legacyAdditions = SSHAlgorithmsLegacySchemes.ordered.filter { !contains(configuredLegacy, $0) }
        result.transportProtectionSchemes = modern + additions + configuredLegacy + legacyAdditions
        result.allowsLegacyAlgorithms = true
        return result
    }

    /// 第一次（用 `first`）以 `failure` 失败后要不要用 `retry` 再试：知道卡在哪一类时，服务器这一类的报价与 `retry`
    /// 比 `first` 多出来的名字有交集才试（再试才可能协商得成）；不知道卡在哪时盲试一次。
    static func shouldRetry(after failure: SSHAlgorithmNegotiationFailure, first: SSHAlgorithms, retry: SSHAlgorithms) -> Bool {
        guard let category = failure.category else { return true }
        let added = retry.names(of: category).subtracting(first.names(of: category))
        return !Set(failure.serverOffer).isDisjoint(with: added)
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

/// `.legacyCompatible` 里旧加密方式的顺序（ETM 在前），补旧算法时照这个顺序接在后面。
nonisolated enum SSHAlgorithmsLegacySchemes {
    static let ordered: [SSHTransportProtections.Scheme] = {
        let legacy = Set(SSHTransportProtections.legacy.map { ObjectIdentifier($0) })
        return SSHAlgorithms.legacyCompatible.transportProtectionSchemes.filter { legacy.contains(ObjectIdentifier($0)) }
    }()
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
