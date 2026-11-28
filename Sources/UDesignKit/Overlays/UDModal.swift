import SwiftUI

/// 自绘模态卡片的外观：`UD.overlay` 实底、**不描边**，靠四周均匀的投影从窗口里浮出来。
///
/// 投影不带纵向偏移，四条边一样深。两层：贴边的一层交代卡片轮廓（浅色下卡片与窗口
/// 都是白底，没有它边缘会糊掉），外面一层是大范围的柔和投影。
///
/// 别再用 `UD.modalShadowColor` 配描边的写法：它在浅色下是透明的，去掉描边后卡片在
/// 白窗口上就没有边界了。
public extension UD {
    enum ModalCard {
        public nonisolated static let cornerRadius: CGFloat = 12
        /// 卡片四周至少留给窗口的空隙：窗口再矮，卡片也不贴到窗口边上，投影才画得出来。
        public nonisolated static let windowInset: CGFloat = 24
        /// 贴边那层投影（radius 1）。
        public nonisolated static let contactShadow = UD.dyn(.black(0.50), .black(0.10))
        /// 外圈柔和投影（radius 18）。
        public nonisolated static let ambientShadow = UD.dyn(.black(0.55), .black(0.16))
    }
}

public extension View {
    /// 套上模态卡片的底、圆角与四周均匀投影（不描边）。只管外观，不管背板与居中；
    /// 自绘居中弹层直接用 `UDModal`。
    func udModalCard(cornerRadius: CGFloat = UD.ModalCard.cornerRadius) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(UD.overlay)
                .shadow(color: UD.ModalCard.contactShadow, radius: 1)
                .shadow(color: UD.ModalCard.ambientShadow, radius: 18)
        }
    }

    /// 系统 `.sheet` 里的弹窗内容统一用的底色、正文色与强调色。
    /// sheet 的窗口外框与投影归系统画，这里只管内容面。
    func udSheetSurface() -> some View {
        background(UD.overlay)
            .foregroundStyle(UD.text)
            .tint(UD.accent)
    }
}

#if os(macOS)
/// 窗口内自绘的居中模态弹层：`UDModalBackdrop`（点外关闭）+ 居中的模态卡片。
///
/// 卡片与窗口四边至少隔 `UD.ModalCard.windowInset`：窗口比卡片矮时卡片跟着缩
/// （内容自己放进 `ScrollView` 才能缩），不会顶到窗口边缘、投影也不被裁掉。
///
/// ```swift
/// .overlay {
///     if let rule = confirmDelete {
///         UDModal(onDismiss: { confirmDelete = nil }) {
///             VStack { … }.padding(20).frame(width: 380)
///         }
///     }
/// }
/// ```
public struct UDModal<Content: View>: View {
    let onDismiss: () -> Void
    let cornerRadius: CGFloat
    let content: Content

    public init(onDismiss: @escaping () -> Void,
                cornerRadius: CGFloat = UD.ModalCard.cornerRadius,
                @ViewBuilder content: () -> Content) {
        self.onDismiss = onDismiss
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        ZStack {
            UDModalBackdrop(onDismiss: onDismiss)
            content
                .udModalCard(cornerRadius: cornerRadius)
                // 读屏：卡片是模态的，VoiceOver 不再游走到背板后面的控件上。
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .padding(UD.ModalCard.windowInset)
        }
    }
}

/// 危险操作（删除等）的确认弹层：红色警示图标、标题、说明，右下「取消 / 删除」。
///
/// 说明由调用方给：纯文案传 `Text`，要混排等宽地址之类就传拼好的 `Text`。
/// 说明的默认色是 `UD.text2`，`Text` 片段自带的颜色优先。
public struct UDConfirmModal<Message: View>: View {
    let title: String
    let confirmTitle: String
    let cancelTitle: String
    let width: CGFloat
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let message: Message

    public init(title: String,
                confirmTitle: String = String(localized: "删除", bundle: ModuleBundle.bundle),
                cancelTitle: String = String(localized: "取消", bundle: ModuleBundle.bundle),
                width: CGFloat = 380,
                onCancel: @escaping () -> Void,
                onConfirm: @escaping () -> Void,
                @ViewBuilder message: () -> Message) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.width = width
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self.message = message()
    }

    public var body: some View {
        UDModal(onDismiss: onCancel) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(UD.danger.opacity(0.14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(UD.danger.opacity(0.3), lineWidth: 1)
                        }
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(UD.danger)
                        }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(UD.text)
                        message
                            .font(.system(size: 12))
                            .foregroundStyle(UD.text2)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    UDButton(title: cancelTitle, style: .secondary, action: onCancel)
                    UDButton(title: confirmTitle, style: .danger, action: onConfirm)
                }
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)
            .frame(width: width)
        }
    }
}
#endif
