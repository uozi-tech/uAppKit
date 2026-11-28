// AppKit 专属组件：iOS 目标（uTermMobile 只消费 Tokens 层）整文件跳过。
#if os(macOS)
import AppKit
import SwiftUI

/// `UDModelPicker` 的一项：某个分组（provider）下的一个模型。
public struct UDModelPickerItem: Identifiable, Hashable, Sendable {
    /// 全局唯一（通常是 `分组 id + 模型 id`）。
    public let id: String
    public let groupID: String
    public let title: String
    /// 行尾的弱化说明（如「不在列表中」）。
    public let detail: String?

    public init(id: String, groupID: String, title: String, detail: String? = nil) {
        self.id = id
        self.groupID = groupID
        self.title = title
        self.detail = detail
    }
}

/// `UDModelPicker` 的一组：一个 provider 及其模型。
public struct UDModelPickerGroup: Identifiable, Sendable {
    public enum Status: Equatable, Sendable {
        case ready
        case loading
        /// 拉取失败；`items` 里仍可能有上次拉到的列表。
        case failed(String)
    }

    public let id: String
    public let title: String
    public let items: [UDModelPickerItem]
    public let status: Status

    public init(id: String, title: String, items: [UDModelPickerItem], status: Status = .ready) {
        self.id = id
        self.title = title
        self.items = items
        self.status = status
    }
}

/// `UDModelPicker` 底部的动作行（「管理模型…」等）。
public struct UDModelPickerAction: Identifiable {
    public let id: String
    let title: String
    let systemImage: String
    let action: () -> Void

    public init(id: String? = nil, title: String, systemImage: String, action: @escaping () -> Void) {
        self.id = id ?? title
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }
}

/// 可搜索、按分组列出的模型选择浮层（放进 `UDDropdown(becomesKey: true)` 的浮层里）。
///
/// 顶部搜索框按模型名或分组名过滤（分组名命中时整组列出）；↑↓ 移动高亮、↩ 选中、esc 关闭
/// （esc 由承载它的 `.anchoredPanel` 处理）。选中后经环境 `udMenuDismiss` 自动收起。
///
/// 纯展示组件：分组、状态、当前选择都由消费方给；不知道什么是 provider。
public struct UDModelPicker: View {
    let groups: [UDModelPickerGroup]
    let selection: String?
    let width: CGFloat
    let placeholder: String
    let isRefreshing: Bool
    let onRefresh: (() -> Void)?
    let actions: [UDModelPickerAction]
    let onSelect: (UDModelPickerItem) -> Void

    @Environment(\.udMenuDismiss) private var dismiss
    @Environment(\.udPanelAvailableHeight) private var panelAvailableHeight
    @State private var query = ""
    @State private var highlighted: String?
    @State private var scrollTarget: ScrollTarget?

    private struct ScrollTarget: Equatable {
        let token = UUID()
        let id: String
        let anchor: UnitPoint?
    }

    /// 列表区上限（约 10 行）。
    public static let listMaxHeight: CGFloat = 340

    /// - Parameters:
    ///   - selection: 当前选中项的 `id`。
    ///   - onRefresh: 非 nil 时搜索框右侧出现刷新钮。
    ///   - actions: 列表下方的动作行（分隔线隔开）。
    public init(
        groups: [UDModelPickerGroup],
        selection: String?,
        width: CGFloat = 300,
        placeholder: String = String(localized: "搜索模型或服务商", bundle: ModuleBundle.bundle),
        isRefreshing: Bool = false,
        onRefresh: (() -> Void)? = nil,
        actions: [UDModelPickerAction] = [],
        onSelect: @escaping (UDModelPickerItem) -> Void
    ) {
        self.groups = groups
        self.selection = selection
        self.width = width
        self.placeholder = placeholder
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        self.actions = actions
        self.onSelect = onSelect
    }

    // MARK: - 过滤

    /// 过滤后要显示的分组：搜索时只留有命中项的组；不搜时全部组都在（含加载中 / 出错的空组）。
    var visibleGroups: [UDModelPickerGroup] {
        UDModelPickerFilter.filter(groups, query: query)
    }

    private var visibleItems: [UDModelPickerItem] {
        visibleGroups.flatMap(\.items)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 视图

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                list
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        proxy.scrollTo(target.id, anchor: target.anchor)
                    }
            }
            if !actions.isEmpty {
                Rectangle().fill(UD.border).frame(height: 1)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                ForEach(actions) { action in
                    UDModelPickerActionRow(action: action) {
                        dismiss()
                        action.action()
                    }
                }
            }
        }
        .padding(4)
        .frame(width: width)
        .background { RoundedRectangle(cornerRadius: 9).fill(UD.overlay) }
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .background { UDModelPickerKeyMonitor(onKey: handle) }
        .onAppear {
            highlighted = selection ?? visibleItems.first?.id
            if let selection {
                // 等首帧布局落定再滚：长列表里选中的是第 30 个，展开直接看到它。
                DispatchQueue.main.async { scrollTarget = ScrollTarget(id: selection, anchor: .center) }
            }
        }
        .onChange(of: query) { _, _ in
            // 搜索时高亮第一条命中，回车就能选；清空搜索回到当前选择。
            highlighted = isSearching ? visibleItems.first?.id : (selection ?? visibleItems.first?.id)
            if let id = highlighted { scrollTarget = ScrollTarget(id: id, anchor: nil) }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            UDSearchField(text: $query, placeholder: placeholder, autoFocus: true,
                          showsHotkeyChip: false, showsFocusRing: false)
                .accessibilityLabel(placeholder)
            if let onRefresh {
                Button(action: onRefresh) {
                    // 刷新中图标自己转圈（同 `UDRefreshButton`），不换成另一个转圈控件。
                    UDSpinningIcon(isSpinning: isRefreshing,
                                   anchor: USymbolMetrics.rotationAnchor("arrow.clockwise") ?? .center) {
                        USymbol("arrow.clockwise", size: 12, box: 13)
                    }
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(UDComposerGhostIconStyle())
                .allowsHitTesting(!isRefreshing)
                .udHelp(String(localized: "重新获取模型列表", bundle: ModuleBundle.bundle),
                        accessibilityName: String(localized: "刷新模型列表", bundle: ModuleBundle.bundle))
            }
        }
        .padding(.bottom, 4)
    }

    /// 列表以外的高度（搜索行 + 外框 padding + 动作行）。都是定高行，直接算，不必实测。
    private var chromeHeight: CGFloat {
        44 + (actions.isEmpty ? 0 : 9 + CGFloat(actions.count) * 30)
    }

    private var listCap: CGFloat {
        UDPanelListCap.cap(Self.listMaxHeight, available: panelAvailableHeight, chrome: chromeHeight)
    }

    private var list: some View {
        // 过滤只跑一遍：`visibleGroups` 是计算属性，每读一次都重新过滤。
        let groups = visibleGroups
        return UDCappedScroll(maxHeight: listCap) {
            VStack(alignment: .leading, spacing: 0) {
                if groups.isEmpty {
                    Text(isSearching ? String(localized: "没有匹配「\(query)」的模型", bundle: ModuleBundle.bundle) : String(localized: "还没有配置模型服务", bundle: ModuleBundle.bundle))
                        .font(UD.font(12))
                        .foregroundStyle(UD.text3)
                        .padding(.horizontal, 9).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(groups) { group in
                    groupHeader(group)
                    ForEach(group.items) { item in
                        UDModelPickerRow(item: item,
                                         selected: item.id == selection,
                                         highlighted: item.id == highlighted,
                                         onHover: { if $0 { highlighted = item.id } },
                                         onTap: { pick(item) })
                            .id(item.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: UDModelPickerGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(UD.font(10.5, weight: .medium))
                    .foregroundStyle(UD.text4)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if group.status == .loading {
                    Text("加载中…", bundle: ModuleBundle.bundle).font(UD.font(10)).foregroundStyle(UD.text4)
                }
            }
            if case .failed(let message) = group.status, !isSearching {
                Text(message)
                    .font(UD.font(10.5))
                    .foregroundStyle(UD.danger)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message)
            } else if group.items.isEmpty, group.status == .ready {
                Text("没有可用模型", bundle: ModuleBundle.bundle).font(UD.font(10.5)).foregroundStyle(UD.text4)
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 8).padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - 选择与键盘

    private func pick(_ item: UDModelPickerItem) {
        onSelect(item)
        dismiss()
    }

    private func handle(_ key: UDModelPickerKeyMonitor.Key) -> Bool {
        let items = visibleItems
        switch key {
        case .up, .down:
            guard !items.isEmpty else { return true }
            let current = highlighted.flatMap { id in items.firstIndex { $0.id == id } }
            let next: Int
            switch (key, current) {
            case (.up, let i?):   next = max(i - 1, 0)
            case (.down, let i?): next = min(i + 1, items.count - 1)
            case (.up, nil):      next = items.count - 1
            default:              next = 0
            }
            highlighted = items[next].id
            scrollTarget = ScrollTarget(id: items[next].id, anchor: nil)
            return true
        case .enter:
            guard let id = highlighted, let item = items.first(where: { $0.id == id }) else { return false }
            pick(item)
            return true
        }
    }
}

/// 过滤规则（单测守它）：不区分大小写、不区分变音符号的子串匹配（`localizedStandardContains`，
/// 同 Finder 搜索）；分组名命中则整组保留。
enum UDModelPickerFilter {
    static func filter(_ groups: [UDModelPickerGroup], query: String) -> [UDModelPickerGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.title.localizedStandardContains(needle) {
                return group.items.isEmpty ? nil : group
            }
            let hits = group.items.filter { $0.title.localizedStandardContains(needle) }
            return hits.isEmpty ? nil : UDModelPickerGroup(id: group.id, title: group.title,
                                                           items: hits, status: group.status)
        }
    }
}

private struct UDModelPickerRow: View {
    let item: UDModelPickerItem
    let selected: Bool
    let highlighted: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    /// hover 行底。提成常量而非在 body 里现调 `UD.dyn`——理由见 `UD.dyn` 的注释。
    private static let highlightBg = UD.dyn(.white(0.05), .black(0.05))

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(UD.font(12.5))
                    .foregroundStyle(selected ? UD.accentInk : UD.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = item.detail {
                    Text(detail).font(UD.font(10.5)).foregroundStyle(UD.text4).lineLimit(1)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UD.accentInk)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 9)
            .background {
                RoundedRectangle(cornerRadius: UD.Radius.sm)
                    .fill(selected ? UD.rowSelected : highlighted ? Self.highlightBg : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: UD.Radius.sm))
        }
        .buttonStyle(.udPlain)
        .onHover(perform: onHover)
        // 行尾说明（如「不在列表中」）也要念出来，不能被标签整个盖掉。
        .udHelp(item.title, accessibilityName: item.detail.map { "\(item.title), \($0)" } ?? item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct UDModelPickerActionRow: View {
    let action: UDModelPickerAction
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: action.systemImage)
                    .font(UD.font(12.5))
                    .frame(width: 14)
                Text(action.title)
                    .font(UD.font(12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(UD.text2)
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background {
                RoundedRectangle(cornerRadius: UD.Radius.sm)
                    .fill(hovering ? UD.panelHover : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: UD.Radius.sm))
        }
        .buttonStyle(.udPlain)
        .onHover { hovering = $0 }
    }
}

/// 浮层里的 ↑↓ / ↩：NSTextField 的 field editor 会先吃掉方向键，`.onKeyPress` 收不到，
/// 所以在本浮层窗口的 keyDown 上挂本地监听（只管发给本窗口的事件，输入法组字时放行）。
struct UDModelPickerKeyMonitor: NSViewRepresentable {
    enum Key { case up, down, enter }

    var onKey: (Key) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onKey = onKey
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.uninstall()
    }

    final class MonitorView: NSView {
        var onKey: ((Key) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            uninstall()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() {
                    return event
                }
                let key: Key?
                switch event.keyCode {
                case 126: key = .up
                case 125: key = .down
                case 36, 76: key = .enter
                default: key = nil
                }
                guard let key, self.onKey?(key) == true else { return event }
                return nil
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        // NSView 只在主线程释放；deinit 本身是 nonisolated 的，直接调 uninstall() 会报
        // 「main actor-isolated」。通常 dismantleNSView / 离开窗口时已经卸掉，这里兜底。
        deinit { MainActor.assumeIsolated { uninstall() } }
    }
}

// MARK: - 输入区工具栏上的两枚下拉

/// Agent 输入区的模型下拉：幽灵触发器（模型名）+ `UDModelPicker` 浮层。uTerm / uTable 共用，
/// 两边长得一样、键盘行为一样。`onOpen` 在浮层出现时调一次（消费方借机刷新过期的列表）。
public struct UDComposerModelMenu: View {
    let label: String
    let help: String
    let maxLabelWidth: CGFloat
    let groups: [UDModelPickerGroup]
    let selection: String?
    let isRefreshing: Bool
    let onOpen: () -> Void
    let onRefresh: (() -> Void)?
    let actions: [UDModelPickerAction]
    let onSelect: (UDModelPickerItem) -> Void

    public init(label: String, help: String, maxLabelWidth: CGFloat = 190,
                groups: [UDModelPickerGroup], selection: String?, isRefreshing: Bool = false,
                onOpen: @escaping () -> Void = {}, onRefresh: (() -> Void)? = nil,
                actions: [UDModelPickerAction] = [],
                onSelect: @escaping (UDModelPickerItem) -> Void) {
        self.label = label
        self.help = help
        self.maxLabelWidth = maxLabelWidth
        self.groups = groups
        self.selection = selection
        self.isRefreshing = isRefreshing
        self.onOpen = onOpen
        self.onRefresh = onRefresh
        self.actions = actions
        self.onSelect = onSelect
    }

    public var body: some View {
        // becomesKey：浮层里有搜索框，要拿键盘焦点。
        UDDropdown(anchor: .leading, becomesKey: true) { open in
            UDComposerGhostLabel(open: open) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: maxLabelWidth)
            }
        } content: {
            UDModelPicker(groups: groups, selection: selection, isRefreshing: isRefreshing,
                          onRefresh: onRefresh, actions: actions, onSelect: onSelect)
                .onAppear(perform: onOpen)
        }
        .fixedSize()
        .help(help)
        .accessibilityLabel(String(localized: "模型", bundle: ModuleBundle.bundle, comment: "模型选择器的读屏标签"))
        .accessibilityValue(label)
    }
}

/// 思考深度的一档。`id == nil` 表示「默认」（不带任何参数，交给模型）。
public struct UDEffortOption: Identifiable, Hashable, Sendable {
    public let value: String?
    public let label: String
    public var id: String { value ?? "" }

    public init(value: String?, label: String) {
        self.value = value
        self.label = label
    }
}

/// Agent 输入区的思考深度下拉：脑图标 + 当前档位。`compact` 只留图标（窄面板）。
public struct UDComposerEffortMenu: View {
    let options: [UDEffortOption]
    let selection: String?
    let compact: Bool
    let onSelect: (String?) -> Void

    public init(options: [UDEffortOption], selection: String?, compact: Bool = false,
                onSelect: @escaping (String?) -> Void) {
        self.options = options
        self.selection = selection
        self.compact = compact
        self.onSelect = onSelect
    }

    private var current: UDEffortOption? {
        options.first { $0.value == selection }
    }

    private var defaultEffortLabel: String { String(localized: "默认", bundle: ModuleBundle.bundle, comment: "思考深度：交给模型的默认档") }

    /// 当前档位；默认档不写字，只亮一个弱化的图标。
    private var isDefault: Bool { selection == nil }

    public var body: some View {
        UDDropdown(anchor: .leading) { open in
            UDComposerGhostLabel(open: open, showsChevron: !compact) {
                Image(systemName: "brain")
                    .font(.system(size: 11.5))
                    .foregroundStyle(isDefault ? UD.text3 : UD.aiAccent)
                if !compact, let current, !isDefault {
                    Text(current.label).lineLimit(1)
                }
            }
        } content: {
            UDMenu(width: 168, head: String(localized: "思考深度", bundle: ModuleBundle.bundle), maxHeight: nil, items: options.map { option in
                UDMenuItem(label: option.label, active: option.value == selection,
                           action: { onSelect(option.value) })
            })
        }
        .fixedSize()
        .help(String(localized: "思考深度：\(current?.label ?? defaultEffortLabel)", bundle: ModuleBundle.bundle))
        .accessibilityLabel(String(localized: "思考深度", bundle: ModuleBundle.bundle))
        .accessibilityValue(current?.label ?? defaultEffortLabel)
    }
}

// MARK: - Preview

#Preview {
    UDModelPicker(
        groups: [
            UDModelPickerGroup(id: "a", title: "Anthropic", items: [
                UDModelPickerItem(id: "a/opus", groupID: "a", title: "claude-opus-4-7"),
                UDModelPickerItem(id: "a/haiku", groupID: "a", title: "claude-haiku-4-5"),
            ]),
            UDModelPickerGroup(id: "d", title: "DeepSeek", items: [], status: .loading),
            UDModelPickerGroup(id: "o", title: "OpenAI", items: [
                UDModelPickerItem(id: "o/gpt", groupID: "o", title: "gpt-5", detail: "不在列表中"),
            ], status: .failed("认证失败，请检查 API Key")),
        ],
        selection: "a/opus",
        onRefresh: {},
        actions: [UDModelPickerAction(title: "管理模型…", systemImage: "slider.horizontal.3") {}],
        onSelect: { _ in })
        .padding(32)
        .background(UD.bg)
}
#endif
