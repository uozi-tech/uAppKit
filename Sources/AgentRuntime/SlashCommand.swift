import Foundation

/// 输入区 `/` 命令表里的一条。命令表与展开（命令 → prompt）由 app 提供，这里只管匹配。
public struct SlashCommand: Identifiable, Sendable, Hashable {
    public let trigger: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    /// nil = 不接参数；非 nil 时在菜单 / 参数态显示的占位说明。
    public let argumentHint: String?
    /// true = 无参数不可执行（选中后只回填 `/trigger `，等用户补参数）。
    public let requiresArgument: Bool

    public var id: String { trigger }

    public init(trigger: String, title: String, subtitle: String = "", systemImage: String = "command",
                argumentHint: String? = nil, requiresArgument: Bool = false) {
        self.trigger = trigger.lowercased()
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.argumentHint = argumentHint
        self.requiresArgument = requiresArgument
    }
}

/// `/` 命令的过滤、token 化与解析。纯逻辑、可单测；弹窗与键盘在 UI 层。
public struct SlashCommandMatcher: Sendable {
    public let commands: [SlashCommand]

    public init(commands: [SlashCommand]) {
        self.commands = commands
    }

    /// 菜单过滤：trigger 前缀，或标题 / 副标题包含（`localizedStandardContains`：不分大小写、
    /// 不分变音符号与全半角，和系统搜索框一致），均可命中；空查询给全表。
    public func matches(for query: String) -> [SlashCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter {
            $0.trigger.hasPrefix(q) || $0.title.localizedStandardContains(q)
                || $0.subtitle.localizedStandardContains(q)
        }
    }

    /// 输入框还在敲命令名（`/` 开头、还没有空白）时返回菜单的查询串，否则 nil。
    public func menuQuery(forDraft draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let body = draft.dropFirst()
        guard !body.contains(where: \.isWhitespace) else { return nil }
        return String(body)
    }

    /// draft 恰好是 `/trigger` + 一个尾随空白（刚敲完空格、还没有参数）时返回对应命令 ——
    /// 面板据此把命令抽成高亮 token。其余形态都返回 nil。
    public func tokenizeDraft(_ draft: String) -> SlashCommand? {
        guard draft.hasPrefix("/"), let last = draft.last, last.isWhitespace else { return nil }
        let token = draft.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { return nil }
        return command(named: token)
    }

    /// `/optimize SELECT …` → (optimize, "SELECT …")；非 `/` 开头或 trigger 未知返回 nil。
    public func parse(_ text: String) -> (command: SlashCommand, argument: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let token = body.prefix(while: { !$0.isWhitespace })
        guard !token.isEmpty, let command = command(named: String(token)) else { return nil }
        let argument = body.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, argument)
    }

    public func command(named trigger: String) -> SlashCommand? {
        let lowered = trigger.lowercased()
        return commands.first { $0.trigger == lowered }
    }
}

/// app 展开一条 `/` 命令的结果。
public enum SlashCommandOutcome: Sendable, Equatable {
    /// 展开成 prompt 作为 user 消息发送；气泡里显示 `display`（通常是用户敲的 `/xxx 参数` 原文）。
    case send(prompt: String, display: String)
    /// 本地动作已处理（如 `/clear` 清空会话），不发消息。
    case handled
    /// 展开失败（缺当前表、编辑器为空…），提示留在输入区。
    case failed(hint: String)
}
