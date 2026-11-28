import SwiftUI

/// uTerm DesignKit 进度原语 —— 线性条 / 不定态条 / 环形 / 传输行，集中于此一文件。
///
/// 全部为纯展示组件：进度值统一为 `Double`（0...1），不依赖任何 domain model。
/// 颜色 / 度量均取自 UD token；进度填充为纯色（无发光），传输卡片带 `udShadow(.sm)`。

public enum UDTransferRowLayout {
    /// 文件传输卡片内容到圆角背景边界的四周内边距。
    public nonisolated static let cardPadding: CGFloat = UD.Space.lg
}

// MARK: - 线性进度条

/// 确定态线性进度条。轨道为半透明 Capsule，填充为 `color` 上色的纯色 Capsule，
/// 宽度按 `progress` 比例（无发光）。
public struct UDLinearBar: View {
    var progress: Double
    var color: Color = UD.accentDefault
    var height: CGFloat = 6

    private var clamped: Double { min(max(progress, 0), 1) }

    public init(progress: Double, color: Color = UD.accentDefault, height: CGFloat = 6) {
        self.progress = progress
        self.color = color
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(UD.uw05)
                    .frame(width: geo.size.width, height: height)

                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * clamped, height: height)
            }
            .frame(height: height)
        }
        .frame(height: height)
        // 两条 Capsule 对辅助功能什么都不是：替身为系统进度条，读得出百分比。
        .accessibilityRepresentation { ProgressView(value: clamped) }
    }
}

// MARK: - 不定态进度条

/// 不定态线性进度条。一根占 40% 宽的 Capsule 在轨道内由 -40% 滑至 100%，
/// 1.4s easeInOut 无限往复。
public struct UDIndeterminateBar: View {
    var height: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(height: CGFloat = 4) {
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let sliderWidth = width * 0.4

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(UD.uw05)
                    .frame(width: width, height: height)

                if reduceMotion {
                    // Reduce Motion：停掉滑动，滑块静置居中（瞬时态）。
                    Capsule()
                        .fill(UD.accent)
                        .frame(width: sliderWidth, height: height)
                        .offset(x: (width - sliderWidth) / 2)
                } else {
                    // 滑块走 CA（见 `Motion/UDMotion.swift`）：SwiftUI `.repeatForever`
                    // 会把整个宿主窗口钉在满帧重绘上，代价跟视图树大小成正比。
                    UDMotionShape(
                        color: UD.accent,
                        content: .fill(cornerRadius: nil,
                                       size: CGSize(width: sliderWidth, height: height)),
                        motion: UDMotion(translationX: .init(from: -sliderWidth, to: width),
                                         duration: 1.4, autoreverses: false,
                                         timing: .easeInEaseOut)
                    )
                    .frame(width: width, height: height)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height)
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityRepresentation { ProgressView() }
    }
}

// MARK: - 环形进度

/// 确定态环形进度。底环半透明，进度环 `color` 上色、圆头、自顶部顺时针，
/// 圆心显示整数百分比。
public struct UDRing: View {
    var progress: Double
    var size: CGFloat = 44
    var color: Color = UD.accentDefault

    private var clamped: Double { min(max(progress, 0), 1) }

    public init(progress: Double, size: CGFloat = 44, color: Color = UD.accentDefault) {
        self.progress = progress
        self.size = size
        self.color = color
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(UD.uw05, lineWidth: 3.5)

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // 纯数字，不进文案目录（不带 bundle 的插值 `Text` 会去 App 主 bundle 查 "%lld"）。
            Text(verbatim: String(Int(clamped * 100)))
                .font(UD.mono(10))
                .foregroundStyle(UD.text2)
        }
        .frame(width: size, height: size)
        // 圆心只是个裸数字「72」，读不出是进度：替身为系统进度条。
        .accessibilityRepresentation { ProgressView(value: clamped) }
    }
}

// MARK: - 传输行

/// 文件传输卡片：标题（方向箭头 + 文件名 + 百分比）、线性进度条、底部速率 / 大小。
///
/// 速率与总大小由调用方给（以前写死成「2.4 MB/s」「x / 12.8 MB」，任何文件都显示这组假数）。
/// 不给就不显示：底行只剩方向。
public struct UDTransferRow: View {
    public enum Direction { case up, down }

    var name: String
    var progress: Double
    var direction: Direction
    var rate: String?
    var totalBytes: Int64?
    var width: CGFloat?

    private var clamped: Double { min(max(progress, 0), 1) }

    /// - Parameters:
    ///   - rate: 已格式化的速率（如 `UFormat.bytes(n) + "/s"`）；nil 不显示。
    ///   - totalBytes: 文件总字节数；给了就在右下显示「已传 / 总量」（已传按 `progress` 折算）。
    ///   - width: 卡片定宽；nil 随父视图。默认 320 与原版一致。
    public init(name: String, progress: Double, direction: Direction,
                rate: String? = nil, totalBytes: Int64? = nil, width: CGFloat? = 320) {
        self.name = name
        self.progress = progress
        self.direction = direction
        self.rate = rate
        self.totalBytes = totalBytes
        self.width = width
    }

    private var directionText: String {
        switch (direction, rate) {
        case (.up, nil): String(localized: "上传", bundle: ModuleBundle.bundle)
        case (.down, nil): String(localized: "下载", bundle: ModuleBundle.bundle)
        case let (.up, rate?):
            String(localized: "上传 · \(rate)", bundle: ModuleBundle.bundle, comment: "传输卡片底行：方向 + 速率，%@ 是已格式化的速率（如 2.4 MB/s）")
        case let (.down, rate?):
            String(localized: "下载 · \(rate)", bundle: ModuleBundle.bundle, comment: "传输卡片底行：方向 + 速率，%@ 是已格式化的速率（如 2.4 MB/s）")
        }
    }

    private var sizeText: String? {
        guard let totalBytes else { return nil }
        let done = Int64((Double(totalBytes) * clamped).rounded(.down))
        return "\(UFormat.bytes(done)) / \(UFormat.bytes(totalBytes))"
    }

    /// 卡片底。提成常量而非在 body 里现调 `UD.dyn`——理由见 `UD.dyn` 的注释。
    private static let cardBg = UD.dyn(.white(0.025), .hex(0xFFFFFF))

    public var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: direction == .up ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UD.accentInk)

                Text(name)
                    .font(UD.mono(11.5))
                    .foregroundStyle(UD.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(verbatim: "\(Int(clamped * 100))%")
                    .font(UD.mono(10.5))
                    .foregroundStyle(UD.text3)
            }

            UDLinearBar(progress: clamped, height: 4)

            HStack {
                Text(verbatim: directionText)
                Spacer()
                if let sizeText {
                    Text(verbatim: sizeText)
                }
            }
            .font(UD.mono(9.5))
            .foregroundStyle(UD.text4)
        }
        .padding(UDTransferRowLayout.cardPadding)
        .frame(width: width)
        .background {
            RoundedRectangle(cornerRadius: UD.Radius.lg)
                .fill(Self.cardBg)
        }
        .overlay {
            RoundedRectangle(cornerRadius: UD.Radius.lg)
                .strokeBorder(UD.border, lineWidth: 1)
        }
        .udShadow(.sm)
    }
}

// MARK: - Preview

#Preview("UDProgress") {
    VStack(alignment: .leading, spacing: UD.Space.xxl) {
        VStack(alignment: .leading, spacing: UD.Space.lg) {
            UDLinearBar(progress: 0.24)
            UDLinearBar(progress: 0.62)
            UDLinearBar(progress: 1.0, color: UD.success)
        }
        .frame(width: 320)

        HStack(spacing: UD.Space.xl) {
            UDRing(progress: 0.30, color: UD.success)
            UDRing(progress: 0.68, color: UD.success)
            UDRing(progress: 0.92, color: UD.success)
        }

        UDIndeterminateBar()
            .frame(width: 320)

        UDTransferRow(name: "banner.png", progress: 0.72, direction: .up,
                      rate: "2.4 MB/s", totalBytes: 13_421_773)
        UDTransferRow(name: "backup-2026.tar.gz", progress: 0.38, direction: .down,
                      rate: "860 KB/s", totalBytes: 1_288_490_189)
    }
    .padding(UD.Space.xxxl)
    .background(UD.bg)
}
