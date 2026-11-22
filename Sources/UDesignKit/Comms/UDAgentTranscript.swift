import SwiftUI

/// Agent 消息流的**渲染窗口**（uTerm `AgentMessageWindow` 收编）。
///
/// 会话数据一条都不裁：受限的只有「同时挂进 SwiftUI 视图树的行数」，超出窗口的旧行由顶部的
/// 「显示更早的 N 条」按需放开。依据：消息流是 `LazyVStack`，但每行里包着非 lazy 的 Markdown，
/// 懒栈只能推迟行的构造、推不掉行的几何维护，挂载与文档高度随会话总长线性增长
/// （uTerm `docs/scroll-perf-findings.md`、uTable `docs/perf-findings-agent-panel.md`，两边都定在 200 条）。
public enum UDTranscriptWindow {
    /// 默认挂载上限。
    public nonisolated static let defaultLimit = 200
    /// 点一次「显示更早」放开多少条。
    public nonisolated static let step = 200

    /// 要挂载的首条下标。`limit <= 0` 或 `limit >= count` 表示不裁。
    public nonisolated static func startIndex(count: Int, limit: Int) -> Int {
        guard count > 0, limit > 0, limit < count else { return 0 }
        return count - limit
    }

    /// 被折叠掉的旧行数（= `startIndex`）。
    public nonisolated static func hiddenCount(count: Int, limit: Int) -> Int {
        startIndex(count: count, limit: limit)
    }

    /// 点一次「显示更早」之后的新上限；不会超过总条数，也不会溢出。剩下不足一步就直接放开全部。
    public nonisolated static func expanded(_ limit: Int, count: Int) -> Int {
        guard limit > 0, limit < count else { return count }
        guard count - limit > step else { return count }
        return limit + step
    }
}

/// 贴底滚动策略（uTerm `AgentScrollPolicy` 收编）。流式文本与 Markdown 排版都按批次刷新，
/// 自动贴底也必须合并，否则每个 SSE 碎片都会启动一次 `LazyVStack` 布局事务。
public enum UDTranscriptScrollPolicy {
    public nonisolated static let coalescingDelay: Double = 0.10
    public nonisolated static let bottomTolerance: CGFloat = 96

    public nonisolated static func isNearBottom(visibleMaxY: CGFloat, contentHeight: CGFloat,
                                                tolerance: CGFloat = bottomTolerance) -> Bool {
        guard visibleMaxY.isFinite, contentHeight.isFinite else { return false }
        return visibleMaxY >= max(0, contentHeight - tolerance)
    }

    /// 贴底跟随要盯的布局量：可滚高度（内容高 − 视口高），以及视口此刻是否在底部容差带里。
    /// 只在这两者变化时才回调，滚动途中的每一帧偏移不会触发。
    public struct TailGeometry: Equatable, Sendable {
        public var scrollableHeight: CGFloat
        public var isNearBottom: Bool

        public init(contentHeight: CGFloat, containerHeight: CGFloat, visibleMaxY: CGFloat) {
            scrollableHeight = contentHeight.isFinite && containerHeight.isFinite
                ? max(0, contentHeight - containerHeight) : 0
            isNearBottom = UDTranscriptScrollPolicy.isNearBottom(visibleMaxY: visibleMaxY,
                                                                 contentHeight: contentHeight)
        }
    }

    /// 原本在底部、而可滚高度变大 = 底边被挤出了视口，跟随中就得补滚一次。
    ///
    /// 只听消息模型不够：流式 Markdown 重排、工具卡展开、排队条带把视口挤矮，最终都只体现在
    /// 可滚高度上。「原本在底部」防的是没有手势相位的滚动（拖滚动条、程序滚动）：懒栈在新位置
    /// 重估行高也会改可滚高度，不加这条就会把人拽回底部。
    public nonisolated static func needsRepin(from old: TailGeometry, to new: TailGeometry) -> Bool {
        old.isNearBottom && new.scrollableHeight > old.scrollableHeight + 0.5
    }
}

/// 贴底滚动的合并器：一个合并窗口里只发一次滚动。视图用 `@State` 持有。
@MainActor
public final class UDTailScrollCoalescer {
    private let delay: Double
    private var pending: DispatchWorkItem?

    public init(delay: Double = UDTranscriptScrollPolicy.coalescingDelay) {
        self.delay = delay
    }

    /// 窗口里已有一次排着就不再排（合并）；否则 `delay` 之后执行。
    public func schedule(_ action: @escaping @MainActor () -> Void) {
        guard pending == nil else { return }
        arm(action)
    }

    /// 取消在排的那次，从现在重新计时（去抖）。
    public func restart(_ action: @escaping @MainActor () -> Void) {
        cancel()
        arm(action)
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    public var isPending: Bool { pending != nil }

    private func arm(_ action: @escaping @MainActor () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = nil
                action()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Agent 消息流：`LazyVStack` + 渲染窗口 + 合并贴底（uTerm `AssistantView` 的做法）。
///
/// 选它而不是 uTable 的非 lazy `VStack`：uTable 换 `VStack` 是因为 `scrollTo("tail")` 在懒栈上
/// 走全量估高、叠上外层 20+ 层弹性容器后卡死；这里贴底不在每次内容变化时 `scrollTo`，
/// 而是盯「可滚高度」并按 100ms 合并（`UDTranscriptScrollPolicy.needsRepin`），配合渲染窗口
/// 把挂载行数封顶在 200，懒栈的估高成本有界。uTerm 有覆盖这一组合的滚动代价测试。
///
/// 纯展示组件：行的类型与内容全由调用方给。
/// - `resetToken`：换会话时变（通常传首行 id），渲染窗口收回默认值。
public struct UDAgentTranscript<Row: Identifiable, RowContent: View, Footer: View, Empty: View>: View {
    let rows: [Row]
    let windowLimit: Int
    let spacing: CGFloat
    let insets: EdgeInsets
    let resetToken: AnyHashable?
    let earlierLabel: (Int) -> String
    @ViewBuilder let row: (Row) -> RowContent
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let empty: () -> Empty

    @State private var expandedLimit: Int?
    @State private var followsTail = true
    @State private var tailScroll = UDTailScrollCoalescer()

    private static var bottomAnchorID: String { "ud.agent.transcript.bottom" }

    public init(
        rows: [Row],
        windowLimit: Int = UDTranscriptWindow.defaultLimit,
        spacing: CGFloat = 18,
        insets: EdgeInsets = EdgeInsets(top: 16, leading: 14, bottom: 0, trailing: 14),
        resetToken: AnyHashable? = nil,
        earlierLabel: @escaping (Int) -> String = { String(localized: "显示更早的 \($0) 条", bundle: ModuleBundle.bundle) },
        @ViewBuilder row: @escaping (Row) -> RowContent,
        @ViewBuilder footer: @escaping () -> Footer,
        @ViewBuilder empty: @escaping () -> Empty
    ) {
        self.rows = rows
        self.windowLimit = windowLimit
        self.spacing = spacing
        self.insets = insets
        self.resetToken = resetToken
        self.earlierLabel = earlierLabel
        self.row = row
        self.footer = footer
        self.empty = empty
    }

    private var effectiveLimit: Int { max(expandedLimit ?? windowLimit, 1) }

    private var mountedRows: ArraySlice<Row> {
        rows[UDTranscriptWindow.startIndex(count: rows.count, limit: effectiveLimit)...]
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: spacing) {
                    if rows.isEmpty {
                        empty()
                    } else {
                        earlierButton
                        ForEach(mountedRows) { item in
                            row(item)
                        }
                    }
                    footer()
                    // 底部留白由锚点自己承担：`scrollTo(_, anchor: .bottom)` 对齐的是锚点底边。
                    Color.clear.frame(height: 10).id(Self.bottomAnchorID)
                }
                .padding(insets)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(TailFollow(followsTail: $followsTail, rowCount: rows.count) {
                scheduleScrollToBottom(proxy)
            })
            .onChange(of: resetToken) { _, _ in
                expandedLimit = nil
                followsTail = true
            }
            .onDisappear { tailScroll.cancel() }
        }
    }

    @ViewBuilder
    private var earlierButton: some View {
        let hidden = UDTranscriptWindow.hiddenCount(count: rows.count, limit: effectiveLimit)
        if hidden > 0 {
            HStack {
                Spacer(minLength: 0)
                Button {
                    expandedLimit = UDTranscriptWindow.expanded(effectiveLimit, count: rows.count)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
                        Text(earlierLabel(min(hidden, UDTranscriptWindow.step))).font(UD.font(11))
                    }
                    .foregroundStyle(UD.text3)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(UD.fillSoft))
                    .contentShape(Capsule())
                }
                .buttonStyle(.udPlain)
                Spacer(minLength: 0)
            }
        }
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy) {
        guard followsTail else { return }
        tailScroll.schedule { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
    }
}

/// 贴底跟随：macOS 15 / iOS 18 起听「可滚高度」与滚动相位；更早的系统退回「行数变了就合并滚一次」。
private struct TailFollow: ViewModifier {
    @Binding var followsTail: Bool
    let rowCount: Int
    let repin: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, iOS 18, *) {
            content
                // `.bottom` 会把短于视口的内容贴到底部、顶上留一大块空白；只覆盖短内容的对齐角色。
                .defaultScrollAnchor(.top, for: .alignment)
                .onScrollPhaseChange { _, phase, context in
                    if phase == .tracking || phase == .interacting {
                        followsTail = false
                    }
                    if phase == .idle {
                        followsTail = UDTranscriptScrollPolicy.isNearBottom(
                            visibleMaxY: context.geometry.visibleRect.maxY,
                            contentHeight: context.geometry.contentSize.height)
                    }
                }
                .onScrollGeometryChange(for: UDTranscriptScrollPolicy.TailGeometry.self) { geometry in
                    UDTranscriptScrollPolicy.TailGeometry(
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height,
                        visibleMaxY: geometry.visibleRect.maxY)
                } action: { old, new in
                    if UDTranscriptScrollPolicy.needsRepin(from: old, to: new) { repin() }
                }
        } else {
            content.onChange(of: rowCount) { _, _ in repin() }
        }
    }
}
