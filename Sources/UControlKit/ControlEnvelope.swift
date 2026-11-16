// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import Foundation

/// 一个动作要过哪道门禁。`ControlDispatcher` 按它统一执行，app 的 handler 不重复判、也不许绕。
public enum ControlGate: Sendable, Hashable {
    /// 不看任何开关（只有 `ping`：否则客户端连「开关关着」都问不出来）。
    case always
    /// 要主开关（「启用命令行接口」）。
    case enabled
    /// 要主开关 + 改动开关（uTable 叫「允许命令行写入」，uTerm 叫「允许执行命令与写入」）。
    case mutation
}

/// 一个动作占哪种连接槽位，见 `ControlSocketServer.Limits`。
public enum ControlOccupancy: Sendable, Hashable {
    /// 秒级返回的请求（`ping`、查询、`run`……）。
    case short
    /// 一占就是几分钟的请求（大文件传输、`terminal-wait`）。它们最多占
    /// `Limits.maxLongLivedClients` 个槽位，剩下的永远留给短请求。
    case longLived
}

/// app 的动作枚举要实现的元数据。用穷举 `switch` 写，新增动作忘了归类就编译不过。
public protocol ControlActionKind: RawRepresentable, Hashable, Sendable where RawValue == String {
    var gate: ControlGate { get }
    var occupancy: ControlOccupancy { get }
}

/// 一条请求。线上是一段 JSON（客户端写完后 `shutdown(SHUT_WR)`），字段由 app 定义。
public protocol ControlRequestEnvelope: Decodable, Sendable {
    associatedtype Action: ControlActionKind
    /// 客户端生成的请求 id，原样回到响应里，并发调用才能对号入座。
    var id: String? { get }
    var action: Action { get }

    /// 把请求体解码成请求。默认就是 `JSONDecoder`；解码失败（含未知动作）服务端回 `invalid_request`。
    static func decode(fromWire data: Data) throws -> Self
}

extension ControlRequestEnvelope {
    public static func decode(fromWire data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

/// 一条响应。**编码归 app**，服务端只负责把编好的字节写出去。
public protocol ControlResponseEnvelope: Encodable, Sendable {
    /// 服务端与分发层自己产生的失败（`server_busy`、`handler_timeout`、门禁……）用它构造。
    /// 不叫 `failure`：两个 app 的响应类型都已经有带额外参数的同名工厂，默认参数不能充当协议见证。
    static func controlFailure(id: String?, code: String, message: String) -> Self

    /// 编成线上的字节。
    ///
    /// 连接上的约定是「心跳空行 / 进度行……、最后一行是响应、然后 EOF」，所以响应必须是**单行**
    /// JSON：按行切的客户端（utermctl）遇上 pretty-print 的多行响应会被切碎；读到 EOF 再整体解析的
    /// 客户端（utablectl）则两种都认。默认实现输出紧凑、键排序、不转义斜杠的单行 JSON，末尾 `\n`。
    /// 自定义实现也不要输出内部换行；结尾没有 `\n` 时服务端会补上。
    func encodedForWire() throws -> Data
}

extension ControlResponseEnvelope {
    public func encodedForWire() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

/// 一次动作失败的统一载体：handler 抛它，`ControlDispatcher` 把它翻成响应。
///
/// `details` 给 app 带额外的结构化载荷（例如 uTerm 的 `host_ambiguous` 带候选主机），
/// 由 app 在 `ControlDispatcher` 的 `failureResponse` 里取出来塞进响应。
public struct ControlFailure: Error, Sendable {
    public var code: String
    public var message: String
    public var details: (any Sendable)?

    public init(code: String, message: String, details: (any Sendable)? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// 核心自己会产生的错误码。都已随两个 app 发过版，客户端按字面值做退出码映射，**不要改**。
///
/// 改动开关的拒绝码不在这里：uTable 发的是 `writes_disabled`，uTerm 发的是 `mutations_disabled`，
/// 由 `ControlDispatcher.Policy.mutationDenied` 传入。
public enum ControlFailureCode {
    /// handler 还没接上（app 启动中）。
    public static let appNotReady = "app_not_ready"
    /// 主开关关着。
    public static let controlDisabled = "control_disabled"
    /// handler 抛了 `ControlFailure` 以外的错误。
    public static let operationFailed = "operation_failed"
    /// 连接数超上限（accept 时就拒、不读请求体），或长连接槽位已满。客户端应退避重试。
    public static let serverBusy = "server_busy"
    /// handler 连续 `handlerIdleTimeout` 没有任何进展。
    public static let handlerTimeout = "handler_timeout"
    /// 请求体不是合法的请求（含未知动作、随附 fd 过多）。
    public static let invalidRequest = "invalid_request"
    public static let emptyRequest = "empty_request"
    public static let requestTooLarge = "request_too_large"
    public static let requestTimeout = "request_timeout"
    public static let responseTimeout = "response_timeout"
    public static let encodeFailed = "encode_failed"
    public static let socketPathTooLong = "socket_path_too_long"
    public static let socketAlreadyServed = "socket_already_served"
}

#endif
