// AppKit 专属组件：iOS 目标（uTermMobile 只消费 Tokens 层）整文件跳过。
#if os(macOS)
import SwiftUI
import AppKit

/// 把自绘内容呈现在一个**无边框、透明、跟随父窗口的子窗口**（NSPanel）里，锚在触发
/// 视图正下方、左对齐 —— 独立窗口天然浮在编辑区 AppKit 宿主视图（HostingScrollView /
/// NSTableView）之上（overlay/`.zIndex` 管不到平台视图，见 v8 §跨区浮层），且**无 popover
/// 箭头**，齐平匹配设计稿的绝对定位下拉（`position:absolute;top;left`）。
///
/// **屏幕边缘**：锚点下方放不下、且下方不足 `anchoredPanelMinComfortHeight` 而上方更宽裕时
/// 改为向上展开；无论哪个方向，都把剩余可用高度经 `udPanelAvailableHeight` 注入内容，
/// 长列表据此限高内滚（`UDMenu` 自动遵守，自绘内容可读此环境值）。
///
/// **单层背景 + 落影**：窗口自身零绘制（`.clear` 底、`hasShadow=false`）—— 开窗口投影会在
/// 内容圆角浮层之外再画一圈灰色圆角、看着像「双重背景」。落影改由内容自带 `udShadow(.md)`
/// 提供，并在四周留 `shadowInset` 透明边让阴影不被窗口裁掉；透明边内的点击照样算「面板外」关闭。
///
/// 用法（挂在触发按钮上）：
/// ```
/// triggerButton
///     .anchoredPanel(isPresented: $open) { dismiss in
///         MyMenu(onPick: { dismiss(); doThing() })   // dismiss 由本组件提供
///     }
/// ```
/// 内容四周留白：给 `udShadow(.md)` 的模糊留空间，透明不可见。
private let anchoredPanelShadowInset: CGFloat = 24

/// 面板离屏幕可见区边缘至少留这么多，不贴死 Dock / 屏幕下沿。
private let anchoredPanelScreenMargin: CGFloat = 8

/// 下方剩余空间不足以放下内容、且上方更宽裕时，改为向上展开。
/// 低于此高度时优先考虑上翻（哪怕内容能滚动，也别挤成几行）。
private let anchoredPanelMinComfortHeight: CGFloat = 160

/// 面板横向摆放（单测守它）。
enum UDAnchoredPanelPlacement {
    /// 把面板 x 推回屏幕可见区：内容（面板去掉两侧 `inset` 留白）离可见区左右边缘至少
    /// `margin`。两边都放不下（内容比屏幕还宽）时贴左边，至少开头看得见。
    static func clampedX(_ x: CGFloat, panelWidth: CGFloat, inset: CGFloat,
                         visible: NSRect?, margin: CGFloat) -> CGFloat {
        guard let visible else { return x }
        let maxX = visible.maxX - margin - (panelWidth - inset)
        let minX = visible.minX + margin - inset
        return max(min(x, maxX), minX)
    }
}

/// `.anchoredPanel` 呈现时注入给内容的**可用最大高度**（内容自身，不含落影留白）——
/// 即锚点到屏幕可见区边缘（避开 Dock / 菜单栏）的距离。内容里的长列表据此限高内滚，
/// 否则会直接伸出屏幕、底下的项既看不见也点不到（`UDMenu` 已自动遵守）。
/// 不在面板里时为 nil。
private struct UDPanelAvailableHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}
public extension EnvironmentValues {
    var udPanelAvailableHeight: CGFloat? {
        get { self[UDPanelAvailableHeightKey.self] }
        set { self[UDPanelAvailableHeightKey.self] = newValue }
    }
}

/// 自绘面板内容里「限高内滚列表」的高度上限计算：固定上限与面板可用高度（扣掉列表以外
/// 的标题 / 搜索框 / 底部行等「外框」）取小，且至少留几行可见。
///
/// 外框高要和列表高在**同一次布局**里得出，一般直接用 `UDPanelListStack`（它内部调这里）；
/// 外框是定高行、能直接算出来时（如 `UDModelPicker`）也可以手动调。
public enum UDPanelListCap {
    /// 屏幕边缘再局促，列表也至少留这么高（约两三行）。
    public static let minimum: CGFloat = 64

    public static func cap(_ maxHeight: CGFloat, available: CGFloat?, chrome: CGFloat) -> CGFloat {
        guard let available else { return maxHeight }
        return max(min(maxHeight, available - chrome), minimum)
    }
}

public extension View {
    /// 实测「整块内容高 − 列表当前高」= 列表以外的外框高，写进 `chrome`（配合
    /// `UDPanelListCap`）。挂在整块面板内容最外层（含 padding）；`listHeight` 传列表
    /// **当前渲染高**，未量到时传 nil（跳过）。
    ///
    /// 只在面板确实受限（环境里有 `udPanelAvailableHeight`，即锚点贴近屏幕边缘）时才挂
    /// 几何观测：外层观测会在列表每次滚动的布局里被重算，实测让导入目标表浮层滚动帧
    /// p95 多出约 2ms（ImportTargetMenuCostTests），不受限时外框高也用不上。
    @available(*, deprecated, message: "外框高下一拍才写回，受限面板会先多出一截再缩回（打开时闪一下）；改用 UDPanelListStack")
    func udPanelChrome(_ chrome: Binding<CGFloat>, listHeight: CGFloat?) -> some View {
        modifier(UDPanelChromeProbe(chrome: chrome, listHeight: listHeight))
    }
}

private struct UDPanelChromeProbe: ViewModifier {
    @Binding var chrome: CGFloat
    let listHeight: CGFloat?
    @Environment(\.udPanelAvailableHeight) private var available

    func body(content: Content) -> some View {
        if available == nil {
            content
        } else {
            // 观测值直接取「外框高」而非整块高：列表高从未知变为已知时整块高可能不变
            // （首帧 maxHeight 已顶到上限），盯整块高就永远等不到回调。
            content.onGeometryChange(for: CGFloat?.self, of: { proxy in
                listHeight.map { max(proxy.size.height - $0, 0) }
            }) { measured in
                // 写回落到下一拍，避免 AttributeGraph 环。
                guard let measured, abs(chrome - measured) > 0.5 else { return }
                DispatchQueue.main.async {
                    guard abs(chrome - measured) > 0.5 else { return }
                    chrome = measured
                }
            }
        }
    }
}

/// 浮层水平对齐：内容左上贴锚点左下（`leading`）/ 内容右上贴锚点右下（`trailing`，
/// 用于贴右边缘的触发器，避免菜单向右溢出窗口）。
public enum UDPanelAlignment { case leading, trailing }

public extension View {
    /// - Parameter becomesKey: 呈现后把面板设为 key window（无边框窗默认不可成 key）——
    ///   面板内含 TextField（如连接菜单的搜索框）需要键盘焦点时传 `true`；纯点选菜单保持
    ///   默认 `false`，避免抢走主窗口按键。
    func anchoredPanel<PanelContent: View>(
        isPresented: Binding<Bool>,
        gap: CGFloat = 6,
        alignment: UDPanelAlignment = .leading,
        becomesKey: Bool = false,
        @ViewBuilder content: @escaping (_ dismiss: @escaping () -> Void) -> PanelContent
    ) -> some View {
        background(AnchoredPanelPresenter(isPresented: isPresented, gap: gap, alignment: alignment, becomesKey: becomesKey, content: content))
    }
}

private struct AnchoredPanelPresenter<PanelContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let gap: CGFloat
    let alignment: UDPanelAlignment
    let becomesKey: Bool
    @ViewBuilder let content: (_ dismiss: @escaping () -> Void) -> PanelContent

    /// 锚点只用来量位置：对命中测试透明。它铺在使用方的 background / overlay 里，大小随锚定内容走，
    /// 放进 overlay 时会盖住底下的控件吞掉点击（uGit 历史表：CI 浮层的锚点挡住了一片提交行）。
    func makeNSView(context: Context) -> NSView { PassthroughAnchorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        coord.anchor = nsView
        coord.gap = gap
        coord.alignment = alignment
        coord.becomesKey = becomesKey
        coord.appearance = nsView.effectiveAppearance
        // dismiss 走 binding：置 false → SwiftUI 重求值 → 下一次 updateNSView 收起。
        let dismiss: () -> Void = { isPresented = false }
        coord.onRequestDismiss = dismiss
        // 内容外套透明边 + 自带 md 落影（窗口零绘制，避免双重背景 / 阴影被裁）。
        // onGeometryChange 盯内容实际尺寸：展开后内容变高/变矮（如搜索过滤）时面板跟着
        // 改 frame——否则 NSHostingView 定格在呈现时的 fittingSize，缩小的内容会被垂直居中。
        coord.buildContent = { [weak coord] availableHeight in
            AnyView(
                content(dismiss)
                    .environment(\.udPanelAvailableHeight, availableHeight)
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                        coord?.contentSizeChanged(size)
                    }
                    .udShadow(.md)
                    .padding(anchoredPanelShadowInset)
            )
        }
        coord.setPresented(isPresented)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    public final class Coordinator {
        weak var anchor: NSView?
        var gap: CGFloat = 6
        var alignment: UDPanelAlignment = .leading
        var becomesKey = false
        var appearance: NSAppearance?
        /// 参数 = 注入内容的可用最大高度（nil = 不限，仅用于先量内容自然高度）。
        var buildContent: ((CGFloat?) -> AnyView)?
        /// 本次呈现是否向上展开（锚点下方放不下时）。呈现期间固定，不随内容尺寸来回翻。
        private var opensUpward = false
        /// presenter 注入的「置 binding=false」。走 binding 而非直接拆窗口，避免同一事件里重入。
        var onRequestDismiss: (() -> Void)?

        private var panel: NSPanel?
        private var hosting: NSHostingView<AnyView>?
        /// 本次呈现注入内容的可用高度（nil = 自然高度放得下）；刷新内容时沿用，不重新定方向。
        private var availableHeight: CGFloat?
        private var localMonitor: Any?

        func setPresented(_ presented: Bool) {
            if presented {
                if panel == nil { present() } else { refreshContent() }
            } else {
                tearDown()
            }
        }

        /// 已展开时宿主再次求值（内容依赖的状态变了，如模型列表加载完）：用最新的 content 替换 rootView。
        /// 视图类型不变，SwiftUI 保留面板里的 @State（搜索框文字、滚动位置）；尺寸变化经
        /// `contentSizeChanged` 跟上。不刷新的话面板内容定格在展开那一刻（一直显示「加载中」）。
        private func refreshContent() {
            guard let hosting, let build = buildContent else { return }
            hosting.rootView = build(availableHeight)
        }

        private func present() {
            guard let anchor, let parent = anchor.window, let build = buildContent else { return }

            // 先不限高量出内容自然高度，再按锚点上下的屏幕空间定方向与可用高度，
            // 重建一次 rootView 把可用高度注入内容——长列表据此内滚，而不是伸出屏幕。
            let hosting = NSHostingView(rootView: build(nil))
            let inset = anchoredPanelShadowInset
            let natural = hosting.fittingSize.height - inset * 2
            let space = availableSpace(anchor: anchor, parent: parent)
            opensUpward = natural > space.below
                && space.below < anchoredPanelMinComfortHeight
                && space.above > space.below
            let available = max(opensUpward ? space.above : space.below, 0)
            availableHeight = natural > available ? available : nil
            if natural > available {
                hosting.rootView = build(available)
            }
            hosting.setFrameSize(hosting.fittingSize)

            let panel: NSPanel = becomesKey
                ? UDKeyableBorderlessPanel(
                    contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false
                )
                : NSPanel(
                    contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false
                )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false         // 落影走内容 udShadow —— 窗口投影会造成「双重背景」
            panel.level = .popUpMenu
            panel.animationBehavior = .none
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.appearance = appearance ?? parent.appearance
            panel.contentView = hosting
            self.panel = panel
            self.hosting = hosting

            parent.addChildWindow(panel, ordered: .above)   // 随父窗口移动自动跟手
            reposition()
            panel.orderFront(nil)
            if becomesKey {
                panel.makeKey()                 // 面板内 TextField 需要键盘焦点
                // 自动聚焦第一个可编辑 TextField：裸 NSHostingView 里 SwiftUI 的
                // @FocusState 不可靠（实测面板 firstResponder 停在窗口自身），
                // 直接 AppKit 层找字段做 firstResponder。下一拍执行 —— hosting
                // 子视图要等首次布局才实体化。
                DispatchQueue.main.async { [weak self] in self?.focusFirstTextField() }
            }
            installDismissMonitor()
        }

        /// 深度优先找 hosting 里第一个可编辑 NSTextField 并夺焦（搜索框自动聚焦）。
        private func focusFirstTextField() {
            guard let panel, let content = panel.contentView else { return }
            func findField(_ v: NSView) -> NSTextField? {
                if let tf = v as? NSTextField, tf.isEditable { return tf }
                for sub in v.subviews { if let f = findField(sub) { return f } }
                return nil
            }
            if let tf = findField(content) { panel.makeFirstResponder(tf) }
        }

        /// 内容尺寸变化（搜索过滤增删行等）→ 面板窗口跟着改 frame，贴锚那条边保持不动。
        /// 内容 ideal 尺寸不依赖容器尺寸（定宽卡片），不会与 setContentSize 形成回环。
        func contentSizeChanged(_ size: CGSize) {
            guard let panel else { return }
            let inset = anchoredPanelShadowInset
            let target = NSSize(width: size.width + inset * 2, height: size.height + inset * 2)
            guard abs(panel.frame.width - target.width) > 0.5
                || abs(panel.frame.height - target.height) > 0.5 else { return }
            panel.setContentSize(target)
            reposition()
        }

        /// 锚点下沿（含 gap）到屏幕可见区下沿、锚点上沿到可见区上沿的距离。
        private func availableSpace(anchor: NSView, parent: NSWindow) -> (below: CGFloat, above: CGFloat) {
            let onScreen = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let screen = NSScreen.screens.first { $0.frame.intersects(onScreen) } ?? parent.screen ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return (.greatestFiniteMagnitude, .greatestFiniteMagnitude) }
            let margin = anchoredPanelScreenMargin
            return (onScreen.minY - gap - visible.minY - margin,
                    visible.maxY - onScreen.maxY - gap - margin)
        }

        private func reposition() {
            guard let anchor, let parent = anchor.window, let panel else { return }
            let rectInWindow = anchor.convert(anchor.bounds, to: nil)
            let onScreen = parent.convertToScreen(rectInWindow)
            let inset = anchoredPanelShadowInset
            // 内容（面板内缩 inset）贴锚点下方、下移 gap；leading=内容左沿对齐锚点左沿，
            // trailing=内容右沿对齐锚点右沿。屏幕坐标 y 向上。
            let aligned: CGFloat = alignment == .leading
                ? onScreen.minX - inset
                : onScreen.maxX - panel.frame.width + inset
            // 锚点贴近屏幕左右边缘时（如靠右的 Agent 侧栏、笔记本小屏），对齐出来的位置会让
            // 内容伸出屏幕被裁掉 —— 横向推回可见区内。
            let screen = NSScreen.screens.first { $0.frame.intersects(onScreen) } ?? parent.screen ?? NSScreen.main
            let x = UDAnchoredPanelPlacement.clampedX(aligned, panelWidth: panel.frame.width, inset: inset,
                                                      visible: screen?.visibleFrame,
                                                      margin: anchoredPanelScreenMargin)
            // 向下：内容顶边贴锚点下沿；向上：内容底边贴锚点上沿。尺寸变化时对应边保持不动。
            let y: CGFloat = opensUpward
                ? onScreen.maxY + gap - inset
                : onScreen.minY - gap + inset - panel.frame.height
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        private func installDismissMonitor() {
            // 内容区点击放行（内容按钮触发后自行 dismiss）；内容区外（含透明留白）/ ESC → 关。
            // 本地监听（非 @Sendable，主线程上下文），结构对齐 UDDropdownDismiss。
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.onRequestDismiss?(); return nil }   // ESC
                    return event
                }
                if event.window == self.panel, self.hitsContent(event) { return event }
                self.onRequestDismiss?()
                return event
            }
        }

        /// 点击是否落在内容矩形内（= 面板去掉四周 inset 留白）。
        private func hitsContent(_ event: NSEvent) -> Bool {
            guard let panel else { return false }
            let inset = anchoredPanelShadowInset
            let p = event.locationInWindow            // 面板窗口坐标（左下原点）
            let w = panel.frame.width, h = panel.frame.height
            return p.x >= inset && p.x <= w - inset && p.y >= inset && p.y <= h - inset
        }

        func tearDown() {
            if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
            if let panel {
                // 面板里的输入框（搜索框）还在编辑时，收起会让字段编辑器 resign，AppKit 当场把攒着的拼写 /
                // 自动更正检查同步跑完，在主线程等 Default QoS 的 DataDetectors 扫描器（Xcode 报优先级反转）。
                // 面板马上销毁，这次检查没有意义：先清掉检查类型。字段编辑器属于本面板，随它一起丢掉。
                (panel.firstResponder as? NSTextView)?.enabledTextCheckingTypes = 0
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
                panel.close()
                self.panel = nil
            }
            hosting = nil
            availableHeight = nil
        }
    }
}

/// 无边框 NSWindow 默认 `canBecomeKey == false`——面板里放 TextField（搜索框）时用本子类
/// 放行成 key，`.nonactivatingPanel` 语义保留（成 key 不激活 app、不抢别家前台）。
private final class UDKeyableBorderlessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
#endif

#if os(macOS)
/// `AnchoredPanelPresenter` 的锚点视图：只提供坐标，不接任何鼠标事件。
final class PassthroughAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
