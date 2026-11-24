import NIOCore

/// 双方在 SSH_MSG_KEXINIT（RFC 4253 §7.1）里各自报出的算法。
struct SSHKeyExchangeOffer: Equatable {
    var keyExchange: [String]
    var hostKey: [String]
    var encryptionClientToServer: [String]
    var encryptionServerToClient: [String]
    var macClientToServer: [String]
    var macServerToClient: [String]
    var compressionClientToServer: [String]
    var compressionServerToClient: [String]
}

/// 挂在 `NIOSSHHandler` 前面（靠 socket 一侧）、只看不改的 handler：从字节流里读出双方的第一个 KEXINIT
/// （一定是明文；版本行之后、它之前只可能有 NIOSSH 也容忍的 SSH_MSG_IGNORE / SSH_MSG_DEBUG），按 NIOSSH 的协商
/// 规则算一遍，协商不出来就立刻说出是哪一类算法、对端报了什么。
///
/// 解析与 NIOSSH 一样宽松：name-list 按 UTF-8 解码（坏字节换成 U+FFFD）后按逗号切、丢掉空项，不限名字长度与字符。
/// 读不懂（版本行后第一个非 IGNORE / DEBUG 的包不是 KEXINIT、包超过 256 KiB、KEXINIT 本身截断）时放弃：
/// 这些情形 NIOSSH 也会失败。放弃了的连接 `negotiated` 为 nil，上层要当「不知道」处理，不能当「没用旧算法」。
///
/// 为什么不等 NIOSSH 报：NIOSSH 的 `keyExchangeNegotiationFailure` 不带任何细节；而且对端常常先发现协商失败、
/// 先关连接——那时我们这边看到的只是对端关闭。KEXINIT 在对端的 DISCONNECT / 关闭之前就到了（双方都是收到对方
/// 版本行就发 KEXINIT），所以在这里判断，结果与「先处理关闭还是先处理 KEXINIT」无关。
///
/// 字节原样往下传，不缓冲、不延迟。两个方向各自只看第一个包，之后什么也不做（重新交换时 KEXINIT 已经加密）。
final class SSHKeyExchangeInitSniffer: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var inbound = Reader()
    private var outbound = Reader()
    private(set) var localOffer: SSHKeyExchangeOffer?
    private(set) var peerOffer: SSHKeyExchangeOffer?
    /// 按双方的 KEXINIT 算出来协商不成时的结果；两边都到齐之前、或协商得成时为 nil。
    private(set) var failure: SSHAlgorithmNegotiationFailure?
    /// 协商得成时选中的算法（同样由双方的 KEXINIT 按 NIOSSH 的规则算出）。
    private(set) var negotiated: SSHNegotiatedAlgorithms?
    /// 本端配置的加密方式：（加密名, MAC 名；AEAD 为 nil）。NIOSSH 协商出名字之后还要找得到一个这样的组合
    /// （加密名相同，MAC 为 nil 或也相同），找不到也算协商失败；选中的组合 MAC 为 nil 时 `encryptionIsAEAD`。
    /// 空（单测直接造的嗅探器）时跳过这一步。
    private let schemes: [Scheme]

    struct Scheme: Equatable {
        var cipher: String
        var mac: String?
    }

    init(schemes: [Scheme] = []) {
        self.schemes = schemes
    }

    /// 第一次得出「协商不成」时调用（在 EventLoop 上，字节已经交给下一个 handler 之后）。
    var onNegotiationFailure: ((SSHAlgorithmNegotiationFailure) -> Void)?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var newFailure: SSHAlgorithmNegotiationFailure?
        if !inbound.isDone {
            let buffer = unwrapInboundIn(data)
            if let offer = inbound.feed(buffer) {
                peerOffer = offer
                newFailure = evaluate()
            }
        }
        context.fireChannelRead(data)
        if let newFailure { onNegotiationFailure?(newFailure) }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var newFailure: SSHAlgorithmNegotiationFailure?
        if !outbound.isDone {
            let buffer = unwrapOutboundIn(data)
            if let offer = outbound.feed(buffer) {
                localOffer = offer
                newFailure = evaluate()
            }
        }
        context.write(data, promise: promise)
        if let newFailure { onNegotiationFailure?(newFailure) }
    }

    /// 两边都到齐时算一次。返回新得出的失败。
    private func evaluate() -> SSHAlgorithmNegotiationFailure? {
        guard failure == nil, negotiated == nil, let localOffer, let peerOffer else { return nil }
        switch Self.negotiate(client: localOffer, server: peerOffer, schemes: schemes) {
        case .success(let result):
            negotiated = result
            return nil
        case .failure(let failure):
            self.failure = failure
            return failure
        }
    }

    // MARK: - 协商（照 NIOSSH 0.15.2 的 SSHKeyExchangeStateMachine.negotiatedAlgorithms）

    /// 按 RFC 4253 §7.1 与 NIOSSH 的实现（只认对称的加密 / MAC 结果，AEAD 也要 MAC 名字对上；压缩只有 `none`）
    /// 判断协商成不成，不成时给出第一个卡住的类别。
    static func negotiate(client: SSHKeyExchangeOffer, server: SSHKeyExchangeOffer,
                          schemes: [Scheme] = []) -> Result<SSHNegotiatedAlgorithms, SSHAlgorithmNegotiationFailure> {
        func failure(_ category: SSHAlgorithmNegotiationFailure.Category,
                     _ clientOffer: [String], _ serverOffer: [String]) -> Result<SSHNegotiatedAlgorithms, SSHAlgorithmNegotiationFailure> {
            .failure(SSHAlgorithmNegotiationFailure(
                category: category,
                clientOffer: clientOffer.filter { !isPseudoAlgorithm($0) },
                serverOffer: serverOffer.filter { !isPseudoAlgorithm($0) }))
        }
        // 密钥交换：客户端列表里第一个对端也有、并且还有双方都有的主机密钥算法的。
        let commonKeyExchange = client.keyExchange.filter { !isPseudoAlgorithm($0) && server.keyExchange.contains($0) }
        if commonKeyExchange.isEmpty {
            return failure(.keyExchange, client.keyExchange, server.keyExchange)
        }
        guard let hostKey = client.hostKey.first(where: server.hostKey.contains) else {
            return failure(.hostKey, client.hostKey, server.hostKey)
        }
        let encryptionC2S = client.encryptionClientToServer.first(where: server.encryptionClientToServer.contains)
        guard let encryptionC2S else {
            return failure(.encryption, client.encryptionClientToServer, server.encryptionClientToServer)
        }
        let encryptionS2C = client.encryptionServerToClient.first(where: server.encryptionServerToClient.contains)
        guard let encryptionS2C else {
            return failure(.encryption, client.encryptionServerToClient, server.encryptionServerToClient)
        }
        let macC2S = client.macClientToServer.first(where: server.macClientToServer.contains)
        guard let macC2S else {
            return failure(.mac, client.macClientToServer, server.macClientToServer)
        }
        let macS2C = client.macServerToClient.first(where: server.macServerToClient.contains)
        guard let macS2C else {
            return failure(.mac, client.macServerToClient, server.macServerToClient)
        }
        // NIOSSH 只支持两个方向协商结果相同（例如服务端两个方向的列表顺序不同就会走到这里）。
        if encryptionC2S != encryptionS2C {
            return failure(.encryption, client.encryptionServerToClient, server.encryptionServerToClient)
        }
        if macC2S != macS2C {
            return failure(.mac, client.macServerToClient, server.macServerToClient)
        }
        // 名字都对上了，还要本端真有这个组合（例如本端是 aes128-ctr + hmac-sha2-256 与 aes256-ctr + hmac-sha2-512，
        // 协商出 aes128-ctr + hmac-sha2-512 就没有可用的实现）。
        var encryptionIsAEAD = false
        if !schemes.isEmpty {
            guard let scheme = schemes.first(where: { $0.cipher == encryptionC2S && ($0.mac == nil || $0.mac == macC2S) })
            else {
                return failure(.encryption, client.encryptionClientToServer, server.encryptionClientToServer)
            }
            encryptionIsAEAD = scheme.mac == nil
        }
        guard let compression = client.compressionClientToServer.first(where: server.compressionClientToServer.contains)
        else {
            return failure(.compression, client.compressionClientToServer, server.compressionClientToServer)
        }
        if !client.compressionServerToClient.contains(where: server.compressionServerToClient.contains) {
            return failure(.compression, client.compressionServerToClient, server.compressionServerToClient)
        }
        return .success(SSHNegotiatedAlgorithms(
            keyExchange: commonKeyExchange[0], hostKey: hostKey, encryption: encryptionC2S, mac: macC2S,
            encryptionIsAEAD: encryptionIsAEAD, compression: compression))
    }

    /// 密钥交换列表里不是算法的标记：`ext-info-c` / `ext-info-s`（RFC 8308）与 strict KEX 的
    /// `kex-strict-c-v00@openssh.com` / `kex-strict-s-v00@openssh.com`。
    static func isPseudoAlgorithm(_ name: String) -> Bool {
        name.hasPrefix("ext-info-") || name.hasPrefix("kex-strict-")
    }

    // MARK: - 读第一个 KEXINIT

    /// 一个方向：跳过版本行（及其前的横幅行，RFC 4253 §4.2）、跳过 KEXINIT 之前的 SSH_MSG_IGNORE（2）与
    /// SSH_MSG_DEBUG（4）——NIOSSH 在初次交换里容忍它们（strict KEX 下它另外要求 KEXINIT 是第一个包，那是它的
    /// 事，不影响这里的判断）——读出 KEXINIT。读不懂（别的类型、超长、格式坏）就放弃，交给 NIOSSH 自己报错。
    struct Reader {
        /// 版本行、横幅、KEXINIT 之前的包与 KEXINIT 合起来的上限。KEXINIT 通常只有 1–2 KiB；NIOSSH 自己的包长
        /// 上限是 256 KiB。
        static let limit = 256 * 1024

        private var buffer = ByteBuffer()
        private var versionSeen = false
        private var consumed = 0
        private(set) var isDone = false

        mutating func feed(_ data: ByteBuffer) -> SSHKeyExchangeOffer? {
            guard !isDone else { return nil }
            var data = data
            buffer.writeBuffer(&data)
            if consumed + buffer.readableBytes > Self.limit { return giveUp() }
            while !versionSeen {
                guard let newline = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
                let length = newline - buffer.readerIndex + 1
                let line = buffer.readSlice(length: length)!
                consumed += length
                if line.readableBytesView.starts(with: Array("SSH-".utf8)) { versionSeen = true }
            }
            while true {
                guard let packetLength = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else { return nil }
                guard packetLength >= 2, Int(packetLength) <= Self.limit else { return giveUp() }
                guard buffer.readableBytes >= 4 + Int(packetLength) else { return nil }
                buffer.moveReaderIndex(forwardBy: 4)
                consumed += 4 + Int(packetLength)
                guard let padding = buffer.readInteger(as: UInt8.self), Int(padding) < Int(packetLength) - 1,
                      var payload = buffer.readSlice(length: Int(packetLength) - 1 - Int(padding)),
                      buffer.readSlice(length: Int(padding)) != nil,
                      let type = payload.getInteger(at: payload.readerIndex, as: UInt8.self) else { return giveUp() }
                switch type {
                case 2, 4:
                    continue                                   // SSH_MSG_IGNORE / SSH_MSG_DEBUG
                case 20:
                    defer { isDone = true; buffer = ByteBuffer() }
                    return Self.parseKeyExchangeInit(&payload)
                default:
                    return giveUp()
                }
            }
        }

        private mutating func giveUp() -> SSHKeyExchangeOffer? {
            isDone = true
            buffer = ByteBuffer()
            return nil
        }

        /// payload：byte 20、16 字节 cookie、10 个 name-list、boolean、uint32。
        static func parseKeyExchangeInit(_ payload: inout ByteBuffer) -> SSHKeyExchangeOffer? {
            guard payload.readInteger(as: UInt8.self) == 20, payload.readSlice(length: 16) != nil else { return nil }
            var lists: [[String]] = []
            for _ in 0..<10 {
                guard let length = payload.readInteger(as: UInt32.self),
                      let bytes = payload.readBytes(length: Int(length)) else { return nil }
                lists.append(nameList(bytes))
            }
            return SSHKeyExchangeOffer(
                keyExchange: lists[0], hostKey: lists[1],
                encryptionClientToServer: lists[2], encryptionServerToClient: lists[3],
                macClientToServer: lists[4], macServerToClient: lists[5],
                compressionClientToServer: lists[6], compressionServerToClient: lists[7])
        }

        /// 与 NIOSSH 的 `readAlgorithms` 一字不差：UTF-8 解码（坏字节换成 U+FFFD），按逗号（字符）切，丢掉空项。
        static func nameList(_ bytes: [UInt8]) -> [String] {
            String(decoding: bytes, as: UTF8.self).split(separator: ",").map(String.init)
        }
    }
}
