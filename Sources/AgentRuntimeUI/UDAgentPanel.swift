// 输入区（`UDAgentComposer`）、排队条带、下拉都是 AppKit 专属组件，面板随之只在 macOS 上提供；
// iOS 上可直接用 `UDAgentTranscript` / `UDAgentApprovalCard` / `AgentTranscriptItems` 自己拼。
#if os(macOS)
import AgentKit
import AgentRuntime
import AppKit
import SwiftUI
import UDesignKit

/// 面板上的文案。默认值走本包的文案目录（`bundle: ModuleBundle.bundle`），调用方也可以整体替换。
public struct UDAgentPanelText: Sendable {
    public var placeholder: String
    public var emptyTitle: String
    public var emptyMessage: String
    public var capabilities: [UDAgentEmptyState.Capability]
    public var suggestions: [String]
    public var emptyActionTitle: String?
    /// 空状态图标块里的 SF Symbol（缺省 `sparkles`；uGit 用消息气泡与标题栏开关统一）。
    public var emptySystemImage: String

    public init(
        placeholder: String = String(localized: "描述目标，交给 Agent 处理…", bundle: ModuleBundle.bundle),
        emptyTitle: String = String(localized: "让 Agent 接手下一步", bundle: ModuleBundle.bundle),
        emptyMessage: String = String(localized: "描述目标即可。需要改动的操作会先请你确认。", bundle: ModuleBundle.bundle),
        capabilities: [UDAgentEmptyState.Capability] = [],
        suggestions: [String] = [],
        emptyActionTitle: String? = nil,
        emptySystemImage: String = "sparkles"
    ) {
        self.placeholder = placeholder
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.capabilities = capabilities
        self.suggestions = suggestions
        self.emptyActionTitle = emptyActionTitle
        self.emptySystemImage = emptySystemImage
    }
}

/// 内置助手面板：把 `AgentRuntimeSession` + `AgentApprovalQueue` 绑到 UDesignKit 的纯展示 agent 视图上。
///
/// 结构（自上而下）：`header` 槽 → 消息流（`UDAgentTranscript`：LazyVStack + 渲染窗口 + 合并贴底）
/// → `/` 命令菜单 → 排队条带 → 输入区（`UDAgentComposer`，`toolbar` 槽放模型 / 思考深度下拉）。
///
/// - `message`：把一段 assistant 文字画出来（app 的 Markdown 渲染器；第二个参数表示还在流式输出）。
/// - `toolCard`：一条工具调用（含结果与状态）怎么画；缺省用 `UDAgentToolTrace`。
/// - 键盘：↩ 发送（忙碌时排到整轮结束），⌘↩ 忙碌时「下一步送达」，esc 停止；`/` 菜单开着时
///   ↑↓ 移动、↩ / Tab 选中、esc 收起。
/// - `/` 命令：`slashCommands` 给命令表，`onSlashCommand` 把命令 + 参数展开成要发的 prompt。
public struct UDAgentPanel<Context: Sendable, Message: View, ToolCard: View, Header: View, Toolbar: View>: View {
    let session: AgentRuntimeSession<Context>
    let approvals: AgentApprovalQueue
    let text: UDAgentPanelText
    let slashCommands: SlashCommandMatcher?
    let onSlashCommand: (SlashCommand, String) -> SlashCommandOutcome
    let onEmptyAction: () -> Void
    @ViewBuilder let message: (String, Bool) -> Message
    @ViewBuilder let toolCard: (AgentToolCallItem) -> ToolCard
    @ViewBuilder let header: () -> Header
    @ViewBuilder let toolbar: () -> Toolbar

    @State private var draft = ""
    @State private var hint: String?
    @State private var slashSelection = 0
    @State private var slashDismissed = false
    @FocusState private var inputFocused: Bool

    public init(
        session: AgentRuntimeSession<Context>,
        approvals: AgentApprovalQueue,
        text: UDAgentPanelText = UDAgentPanelText(),
        slashCommands: SlashCommandMatcher? = nil,
        onSlashCommand: @escaping (SlashCommand, String) -> SlashCommandOutcome = { _, _ in .handled },
        onEmptyAction: @escaping () -> Void = {},
        @ViewBuilder message: @escaping (String, Bool) -> Message,
        @ViewBuilder toolCard: @escaping (AgentToolCallItem) -> ToolCard,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder toolbar: @escaping () -> Toolbar
    ) {
        self.session = session
        self.approvals = approvals
        self.text = text
        self.slashCommands = slashCommands
        self.onSlashCommand = onSlashCommand
        self.onEmptyAction = onEmptyAction
        self.message = message
        self.toolCard = toolCard
        self.header = header
        self.toolbar = toolbar
    }

    public var body: some View {
        let items = session.transcriptItems
        VStack(spacing: 0) {
            header()
            UDAgentTranscript(rows: items, resetToken: items.first?.id) { item in
                row(item)
            } footer: {
                footer
            } empty: {
                UDAgentEmptyState(
                    systemImage: text.emptySystemImage,
                    title: text.emptyTitle, message: text.emptyMessage, capabilities: text.capabilities,
                    suggestions: text.suggestions, actionTitle: text.emptyActionTitle,
                    onSuggestion: { draft = $0; inputFocused = true }, onAction: onEmptyAction)
            }
            slashOverlay
            UDAgentQueueStrip(
                items: session.queuedMessages.map { item in
                    UDAgentQueueItem(id: item.id, text: session.queuedDisplayOverrides[item.id] ?? item.text,
                                     sendsAtNextStep: item.delivery == .nextStep)
                },
                onSendNow: { session.sendQueuedAtNextStep(id: $0) },
                onEdit: { id in
                    if let restored = session.takeQueuedForEditing(id: id) {
                        draft = restored
                        inputFocused = true
                    }
                },
                onRemove: { session.removeQueued(id: $0) })
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 0, trailing: 10))
            composer
        }
        .background(commandReturnShortcut)
    }

    // MARK: - 行

    @ViewBuilder
    private func row(_ item: AgentTranscriptItem) -> some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(UD.font(12.5))
                    .foregroundStyle(UD.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 11).fill(UD.accentTint))
            }
        case .assistant(let content, let calls):
            VStack(alignment: .leading, spacing: 8) {
                if let content { message(content, false) }
                ForEach(calls) { call in toolCard(call) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .orphanToolResult(_, let content, let isError):
            UDAgentToolTrace(name: String(localized: "结果", bundle: ModuleBundle.bundle, comment: "没有对应工具调用的工具结果的标题"), arguments: "", result: content, status: isError ? .failed : .done)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let streaming = session.streamingText, !streaming.isEmpty {
            message(streaming, true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let pending = approvals.pending {
            let request = pending.request
            UDAgentApprovalCard(
                toolName: request.toolName, reason: request.reason, note: request.policyNote,
                detail: request.displayText, isDestructive: !request.allowsSessionGrant,
                onDeny: { approvals.decide(.denied, for: pending.id) },
                onAllow: { approvals.decide(.granted, for: pending.id) },
                onAllowForSession: request.allowsSessionGrant
                    ? { approvals.decide(.grantedForSession, for: pending.id) } : nil)
            .id(pending.id)
        } else if let line = session.statusLine {
            switch line {
            case .busy(let label):
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(label).font(UD.font(11.5)).foregroundStyle(UD.text3)
                }
            case .error(let message):
                Text(message)
                    .font(UD.font(11.5))
                    .foregroundStyle(UD.danger)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 输入区

    private var composer: some View {
        UDAgentComposer(
            text: $draft,
            placeholder: text.placeholder,
            status: hint,
            canSend: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            canStop: session.isBusy,
            focus: $inputFocused,
            onSend: { submit(delivery: .afterTurn) },
            onStop: { session.cancel() },
            toolbar: toolbar)
        .padding(10)
        .background(SlashKeyInterceptor(isActive: !slashMatches.isEmpty, onKey: handleSlashKey))
        .onChange(of: draft) { _, _ in
            hint = nil
            if slashCommands?.menuQuery(forDraft: draft) == nil { slashDismissed = false }
            slashSelection = 0
        }
    }

    /// ⌘↩：忙碌时「立即发送」（这一步跑完就送达，不打断）。
    private var commandReturnShortcut: some View {
        Button("") { submit(delivery: .nextStep) }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.udPlain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func submit(delivery: AgentQueuedMessage.Delivery) {
        if acceptSelectedSlash() { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let slashCommands, let (command, argument) = slashCommands.parse(trimmed) {
            switch onSlashCommand(command, argument) {
            case .send(let prompt, let display):
                send(prompt, display: display, delivery: delivery)
            case .handled:
                draft = ""
            case .failed(let message):
                hint = message
            }
            return
        }
        send(trimmed, display: nil, delivery: delivery)
    }

    private func send(_ prompt: String, display: String?, delivery: AgentQueuedMessage.Delivery) {
        draft = ""
        let session = session
        Task { await session.submit(prompt, displayAs: display, delivery: delivery) }
    }

    // MARK: - `/` 命令菜单

    private var slashMatches: [SlashCommand] {
        guard !slashDismissed, let slashCommands, let query = slashCommands.menuQuery(forDraft: draft),
              !draft.contains("\n") else { return [] }
        return slashCommands.matches(for: query)
    }

    @ViewBuilder
    private var slashOverlay: some View {
        let matches = slashMatches
        if !matches.isEmpty {
            let selected = matches[min(slashSelection, matches.count - 1)]
            UDSlashMenu(
                items: matches.map {
                    UDSlashMenuItem(trigger: $0.trigger, title: $0.title, subtitle: $0.subtitle,
                                    systemImage: $0.systemImage)
                },
                selectedID: selected.trigger
            ) { item in
                if let command = slashCommands?.command(named: item.trigger) { accept(command) }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
    }

    private func handleSlashKey(_ key: SlashKeyInterceptor.Key) -> Bool {
        let matches = slashMatches
        guard !matches.isEmpty else { return false }
        switch key {
        case .up:
            slashSelection = (min(slashSelection, matches.count - 1) - 1 + matches.count) % matches.count
            return true
        case .down:
            slashSelection = (min(slashSelection, matches.count - 1) + 1) % matches.count
            return true
        case .tab, .ret:
            return acceptSelectedSlash()
        case .escape:
            slashDismissed = true
            return true
        }
    }

    private func acceptSelectedSlash() -> Bool {
        let matches = slashMatches
        guard !matches.isEmpty else { return false }
        accept(matches[min(slashSelection, matches.count - 1)])
        return true
    }

    /// 选中命令：回填 `/trigger `，等用户补参数或直接 ↩ 发送。
    private func accept(_ command: SlashCommand) {
        draft = "/\(command.trigger) "
        inputFocused = true
    }
}

// MARK: - 缺省槽

/// 缺省的 assistant 文字：内联 Markdown（加粗、代码、链接），保留换行。块级 Markdown
/// （列表、代码块、表格）请传 app 自己的渲染器。
public struct UDAgentPlainMessage: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(Self.attributed(text))
            .font(UD.font(12.5))
            .lineSpacing(3)
            .foregroundStyle(UD.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// 缺省的工具卡。
public struct UDAgentDefaultToolCard: View {
    let item: AgentToolCallItem
    public init(_ item: AgentToolCallItem) { self.item = item }

    public var body: some View {
        UDAgentToolTrace(name: item.call.name, arguments: item.call.arguments, result: item.result,
                         status: Self.status(item.status))
    }

    static func status(_ status: AgentToolCallItem.Status) -> UDAgentToolTrace.Status {
        switch status {
        case .pending: return .pending
        case .running: return .running
        case .succeeded: return .done
        case .failed: return .failed
        }
    }
}

extension UDAgentPanel where Message == UDAgentPlainMessage, ToolCard == UDAgentDefaultToolCard {
    /// 缺省的文字与工具卡；只给头部与工具栏。
    public init(
        session: AgentRuntimeSession<Context>,
        approvals: AgentApprovalQueue,
        text: UDAgentPanelText = UDAgentPanelText(),
        slashCommands: SlashCommandMatcher? = nil,
        onSlashCommand: @escaping (SlashCommand, String) -> SlashCommandOutcome = { _, _ in .handled },
        onEmptyAction: @escaping () -> Void = {},
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder toolbar: @escaping () -> Toolbar
    ) {
        self.init(session: session, approvals: approvals, text: text, slashCommands: slashCommands,
                  onSlashCommand: onSlashCommand, onEmptyAction: onEmptyAction,
                  message: { text, _ in UDAgentPlainMessage(text) },
                  toolCard: { UDAgentDefaultToolCard($0) },
                  header: header, toolbar: toolbar)
    }
}

// MARK: - `/` 菜单按键拦截

/// `/` 命令菜单的键盘循环（uTable `SlashKeyInterceptor` 收编）：NSEvent local monitor 在 field
/// editor 之前拦下 ↑↓ / Tab / ↩ / esc（`.onKeyPress` 在 macOS 上收不到被 field editor 消费的键）。
/// 门控：菜单开着、事件属于本窗口、正在编辑的正是本面板的输入框；输入法组字中一律放行。
struct SlashKeyInterceptor: NSViewRepresentable {
    enum Key { case up, down, tab, escape, ret }

    var isActive: Bool
    var onKey: (Key) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.isActive = isActive
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.isActive = isActive
        nsView.onKey = onKey
    }

    final class MonitorView: NSView {
        var isActive = false
        var onKey: ((Key) -> Bool)?
        nonisolated(unsafe) private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { removeMonitor() } else { installMonitor() }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let keyCode = event.keyCode
                let modifiers = event.modifierFlags
                let eventWindow = event.window
                // 监听回调总在主线程；只把判定结果（Bool）带出隔离域，NSEvent 本身不跨。
                let swallow = MainActor.assumeIsolated {
                    self?.shouldSwallow(keyCode: keyCode, modifiers: modifiers, eventWindow: eventWindow) ?? false
                }
                return swallow ? nil : event
            }
        }

        private func shouldSwallow(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, eventWindow: NSWindow?) -> Bool {
            guard isActive, let window, eventWindow === window,
                  modifiers.intersection([.command, .option, .control]).isEmpty else { return false }
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            guard composerFieldIsEditing() else { return false }
            let key: Key?
            switch keyCode {
            case 126: key = .up
            case 125: key = .down
            case 48: key = .tab
            case 53: key = .escape
            case 36, 76: key = .ret
            default: key = nil
            }
            guard let key else { return false }
            return onKey?(key) == true
        }

        /// 正在编辑的文本框是否就在本输入区的容器里。
        private func composerFieldIsEditing() -> Bool {
            var node: NSView? = self
            for _ in 0..<6 {
                node = node?.superview
                guard let container = node else { return false }
                if let field = Self.editingTextField(in: container) {
                    return field.currentEditor() != nil
                }
            }
            return false
        }

        private static func editingTextField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.currentEditor() != nil { return field }
            for sub in view.subviews {
                if let found = editingTextField(in: sub) { return found }
            }
            return nil
        }
    }
}
#endif
