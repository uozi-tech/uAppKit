import AgentKit
import AgentProviders
import Foundation
import SwiftData

/// 聊天记录写穿层：内存 → 库单向写穿 —— `AgentRuntimeSession` 每 append 一条消息就经
/// `recorder` 落一条（或改一条）记录；库只在显式 `load` / `reopenCurrent` 时反向读取。
///
/// - 存的是 AgentKit 的 `ChatSession` / `ChatMessageRecord`（字段一个不改），形状由 codec 决定。
/// - 会话惰性创建：首条 user 消息才建 `ChatSession`，空面板不污染历史。
/// - `scopeID` 把会话归到 app 的某个作用域下（uTable 的连接、uGit 的仓库）；nil = 不分作用域。
/// - `context` 由 app 给：`ChatSession` / `ChatMessageRecord` 注册在 app 自己的容器里
///   （不放进共享 provider 容器）。
@MainActor
public final class AgentChatStore {
    public let context: ModelContext
    public let codec: any AgentTranscriptCodec
    public private(set) var currentSession: ChatSession?

    public init(context: ModelContext, codec: any AgentTranscriptCodec = ToolRowsTranscriptCodec()) {
        self.context = context
        self.codec = codec
    }

    /// 接到 `AgentRuntimeSession.recorder` 上：
    /// `session.recorder = { [weak store] message, display in store?.record(message, display: display, scopeID: id) }`
    public func record(_ message: AgentMessage, display: String?, scopeID: UUID?) {
        if currentSession == nil {
            guard case .user(let text) = message else { return }
            let session = ChatSession(title: AgentTitle.derive(from: display ?? text), scopeID: scopeID)
            context.insert(session)
            currentSession = session
        }
        guard let session = currentSession else { return }
        let ordered = session.orderedMessages
        switch codec.encode(message, display: display, lastRow: ordered.last.map(AgentTranscriptRow.init)) {
        case .skip:
            return
        case .append(let row):
            let record = ChatMessageRecord(roleRaw: row.roleRaw, text: row.text,
                                           orderIndex: nextOrderIndex(ordered))
            row.apply(to: record)
            record.session = session
            context.insert(record)
        case .replaceLast(let row):
            guard let last = ordered.last else { return }
            row.apply(to: last)
        }
        session.updatedAt = Date()
        try? context.save()
    }

    /// 新对话：只断开指针，不写库（下次发送再惰性建会话）。
    public func startNewChat() {
        currentSession = nil
    }

    /// 显式加载一条历史会话（历史下拉点选）。
    public func load(_ session: ChatSession) -> AgentRestoredTranscript {
        currentSession = session
        return codec.decode(session.orderedMessages.map(AgentTranscriptRow.init))
    }

    /// 会话重建时的接续：当前指针还指着该作用域的会话就继续用；否则捞该作用域最近一条历史
    /// （应用重启后的自动恢复）。都没有返回 nil。
    public func reopenCurrent(scopeID: UUID?) -> AgentRestoredTranscript? {
        if let current = currentSession, current.scopeID == scopeID {
            return load(current)
        }
        currentSession = nil
        guard let latest = sessions(scopeID: scopeID, limit: 1).first else { return nil }
        return load(latest)
    }

    /// 某个作用域下的会话，最近活动的在前。
    public func sessions(scopeID: UUID?, limit: Int? = nil) -> [ChatSession] {
        var descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.scopeID == scopeID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    public func delete(_ session: ChatSession) {
        if currentSession?.id == session.id { currentSession = nil }
        context.delete(session)
        try? context.save()
    }

    /// 把一个字符串作用域（如仓库路径）换成稳定的 `scopeID`：同一输入永远同一个 UUID。
    public nonisolated static func scopeID(for key: String, namespace: String = "agent-scope") -> UUID {
        DeterministicUUID.make(namespace: namespace, name: key)
    }

    private func nextOrderIndex(_ ordered: [ChatMessageRecord]) -> Int {
        (ordered.map(\.orderIndex).max() ?? -1) + 1
    }
}
