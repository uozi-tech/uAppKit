import SwiftUI
import AppKit

/// 把自绘内容呈现在一个**无边框、透明、跟随父窗口的子窗口**（NSPanel）里，锚在触发
/// 视图正下方、左对齐 —— 独立窗口天然浮在编辑区 AppKit 宿主视图（HostingScrollView /
/// NSTableView）之上（overlay/`.zIndex` 管不到平台视图，见 v8 §跨区浮层），且**无 popover
/// 箭头**，齐平匹配设计稿的绝对定位下拉（`position:absolute;top;left`）。
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

/// 浮层水平对齐：内容左上贴锚点左下（`leading`）/ 内容右上贴锚点右下（`trailing`，
/// 用于贴右边缘的触发器，避免菜单向右溢出窗口）。
public enum UDPanelAlignment { case leading, trailing }

public extension View {
    func anchoredPanel<PanelContent: View>(
        isPresented: Binding<Bool>,
        gap: CGFloat = 6,
        alignment: UDPanelAlignment = .leading,
        @ViewBuilder content: @escaping (_ dismiss: @escaping () -> Void) -> PanelContent
    ) -> some View {
        background(AnchoredPanelPresenter(isPresented: isPresented, gap: gap, alignment: alignment, content: content))
    }
}

private struct AnchoredPanelPresenter<PanelContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let gap: CGFloat
    let alignment: UDPanelAlignment
    @ViewBuilder let content: (_ dismiss: @escaping () -> Void) -> PanelContent

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        coord.anchor = nsView
        coord.gap = gap
        coord.alignment = alignment
        coord.appearance = nsView.effectiveAppearance
        // dismiss 走 binding：置 false → SwiftUI 重求值 → 下一次 updateNSView 收起。
        let dismiss: () -> Void = { isPresented = false }
        coord.onRequestDismiss = dismiss
        // 内容外套透明边 + 自带 md 落影（窗口零绘制，避免双重背景 / 阴影被裁）。
        coord.buildContent = {
            AnyView(content(dismiss).udShadow(.md).padding(anchoredPanelShadowInset))
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
        var appearance: NSAppearance?
        var buildContent: (() -> AnyView)?
        /// presenter 注入的「置 binding=false」。走 binding 而非直接拆窗口，避免同一事件里重入。
        var onRequestDismiss: (() -> Void)?

        private var panel: NSPanel?
        private var localMonitor: Any?

        func setPresented(_ presented: Bool) {
            if presented {
                if panel == nil { present() }
            } else {
                tearDown()
            }
        }

        private func present() {
            guard let anchor, let parent = anchor.window, let build = buildContent else { return }

            let hosting = NSHostingView(rootView: build())
            hosting.setFrameSize(hosting.fittingSize)

            let panel = NSPanel(
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

            parent.addChildWindow(panel, ordered: .above)   // 随父窗口移动自动跟手
            reposition()
            panel.orderFront(nil)
            installDismissMonitor()
        }

        private func reposition() {
            guard let anchor, let parent = anchor.window, let panel else { return }
            let rectInWindow = anchor.convert(anchor.bounds, to: nil)
            let onScreen = parent.convertToScreen(rectInWindow)
            let inset = anchoredPanelShadowInset
            // 内容（面板内缩 inset）贴锚点下方、下移 gap；leading=内容左沿对齐锚点左沿，
            // trailing=内容右沿对齐锚点右沿。屏幕坐标 y 向上。
            let x: CGFloat = alignment == .leading
                ? onScreen.minX - inset
                : onScreen.maxX - panel.frame.width + inset
            let origin = NSPoint(x: x, y: onScreen.minY - gap + inset - panel.frame.height)
            panel.setFrameOrigin(origin)
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
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
                panel.close()
                self.panel = nil
            }
        }
    }
}
