import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - 为什么有这个文件
//
// SwiftUI 的常驻动画（`.repeatForever`）会把整个 `NSHostingView` / `UIHostingController`
// 钉在「每帧重跑 render + display list diff」的状态，代价跟**整棵视图树**的大小成正比，
// 而不是跟动画元素的大小成正比。更糟的是它**不看窗口可不可见** —— 窗口在别的 Space、
// app 被隐藏，照样满帧跑。
//
// 2026-09-20 在 uTerm 1.16.4 上实测（2304×1296 @ 120Hz）：欢迎页里两个用本包
// `UDHostDot` 画的呼吸点，让 app **空载吃 30%+ CPU**、把 WindowServer 顶到 **61%**，
// 而当时一个窗口都不在可见 Space 上。`sample` 显示主线程 2/3 的时间在
// render → display list diff → 把一屏 `Text` 全部重新栅格化 → commit → 请求下一帧
// 的闭环里打转（文本陪葬是因为 SwiftUI 把未提升成独立 layer 的内容拍平进了同一张
// `CGDrawingLayer`，里面变一处就整张重画）。打开「减弱动态效果」CPU 立刻归零。
//
// 所以本包里所有「永远在动的小装饰」都下沉到 Core Animation：插值发生在渲染服务器，
// 主线程每帧 0 开销，窗口不可见时系统根本不合成它。
//
// 自 v1.4.13 起这些图元是**公开 API**：uTable 的 Redis 订阅指示点等场景需要同一套
// 东西，不能各抄一份（uTerm 已有一份 `CAMotion.swift`，再抄第三份就失控了）。
//
// 消费方优先用成品组件（`UDPulseHalo` / `UDBreathingDot` / `UDHostDot` /
// `UDStatusBadge`）；形状或动画对不上时再用底层的 `UDMotionShape` 自己拼。

// MARK: - 图元描述

/// 图元内容。
public enum UDMotionContent: Equatable {
    /// 填充形状。
    /// - `cornerRadius`: nil = 取短边一半（圆 / 胶囊）。
    /// - `size`: nil = 填满 bounds；给定时靠**左**、垂直居中放置（配合
    ///   `translationX` 做滑块）。
    case fill(cornerRadius: CGFloat?, size: CGSize?)
    /// 描边圆弧。`trim` 为弧长占整圈的比例。
    case arc(trim: CGFloat, lineWidth: CGFloat)
}

/// 一对「从 → 到」的动画端点。
///
/// 不用 `ClosedRange` —— 它要求 `lowerBound <= upperBound`，而动画端点经常是**反向**的
/// （不透明度 0.3 → 0）。用 `ClosedRange` 写会在构造时直接
/// `Fatal error: Range requires lowerBound <= upperBound`。
public struct UDMotionRamp<Value: Equatable>: Equatable {
    public var from: Value
    public var to: Value

    public init(from: Value, to: Value) {
        self.from = from
        self.to = to
    }
}

/// 一段无限循环动画。`Equatable` 用于「参数没变就不重启动画」—— 否则每次
/// `updateNSView`（父视图任意重绘都会触发）都把动画从头播一遍，看起来像卡顿。
public struct UDMotion: Equatable {
    /// 不透明度端点。nil = 不动不透明度。
    public var opacity: UDMotionRamp<Double>?
    /// 缩放端点。nil = 不缩放。
    public var scale: UDMotionRamp<CGFloat>?
    /// 横向位移端点（pt）。nil = 不位移。
    public var translationX: UDMotionRamp<CGFloat>?
    /// 是否绕中心匀速转整圈。
    public var spins: Bool
    public var duration: TimeInterval
    public var autoreverses: Bool
    public var timing: CAMediaTimingFunctionName

    public init(opacity: UDMotionRamp<Double>? = nil,
         scale: UDMotionRamp<CGFloat>? = nil,
         translationX: UDMotionRamp<CGFloat>? = nil,
         spins: Bool = false,
         duration: TimeInterval,
         autoreverses: Bool,
         timing: CAMediaTimingFunctionName) {
        self.opacity = opacity
        self.scale = scale
        self.translationX = translationX
        self.spins = spins
        self.duration = duration
        self.autoreverses = autoreverses
        self.timing = timing
    }
}

// MARK: - 承载视图

#if canImport(AppKit)
typealias UDMotionBaseView = NSView
#elseif canImport(UIKit)
typealias UDMotionBaseView = UIView
#endif

/// 承载图元的平台视图。只做三件事：按 bounds 画 path、上色、挂动画。
final class UDMotionView: UDMotionBaseView {
    private static let animationKey = "udesignkit.motion"

    private let shape = CAShapeLayer()
    private var content: UDMotionContent?
    /// 外层 nil = 还没配过；内层 nil = 明确不要动画（如 Reduce Motion）。
    private var motion: UDMotion??
    private var resolved: CGColor?

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        #if canImport(AppKit)
        wantsLayer = true
        layer?.masksToBounds = false
        #else
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = false
        #endif
        // 基线全透明：可见度由动画的 fromValue 给，动画一旦被摘掉就自然隐身。
        // 无 opacity 动画的图元会在 configure 里把它拨回 1。
        shape.opacity = 0
        platformLayer.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("UDMotionView 不从 nib 加载") }

    private var platformLayer: CALayer {
        #if canImport(AppKit)
        return layer!
        #else
        return layer
        #endif
    }

    #if canImport(AppKit)
    override func layout() {
        super.layout()
        syncGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 重新入树时 CA 可能已经把动画摘了（layer 离开 layer tree 会丢动画），补挂一次。
        if window != nil { restartAnimation() }
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        syncGeometry()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { restartAnimation() }
    }
    #endif

    func configure(content: UDMotionContent, motion: UDMotion?, color: CGColor) {
        if self.content != content {
            self.content = content
            syncGeometry()
        }
        if resolved != color {
            resolved = color
            applyColor()
        }
        if self.motion == nil || self.motion! != motion {
            self.motion = .some(motion)
            withoutImplicitAnimations { shape.opacity = motion?.opacity == nil ? 1 : 0 }
            restartAnimation()
        }
    }

    /// 几何 / 上色变更必须关隐式动画，否则 AppKit / UIKit 会补一段淡入，
    /// 跟我们自己的循环动画打架。
    private func withoutImplicitAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func syncGeometry() {
        guard let content, bounds.width > 0, bounds.height > 0 else { return }
        withoutImplicitAnimations {
            switch content {
            case .fill(let cornerRadius, let size):
                let box: CGRect
                if let size {
                    // 靠左、垂直居中 —— 配合 translationX 当滑块用。
                    box = CGRect(x: 0, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height)
                } else {
                    box = bounds
                }
                shape.frame = box
                let local = CGRect(origin: .zero, size: box.size)
                let radius = cornerRadius ?? min(box.width, box.height) / 2
                shape.path = CGPath(roundedRect: local, cornerWidth: radius,
                                    cornerHeight: radius, transform: nil)
                shape.fillColor = resolved
                shape.strokeColor = nil
                shape.lineWidth = 0
            case .arc(let trim, let lineWidth):
                shape.frame = bounds
                // 描边按线宽内缩半线宽，弧才不会被 bounds 切掉外沿。
                let rect = CGRect(origin: .zero, size: bounds.size)
                    .insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                shape.path = CGPath(ellipseIn: rect, transform: nil)
                shape.fillColor = nil
                shape.strokeColor = resolved
                shape.lineWidth = lineWidth
                shape.lineCap = .round
                shape.strokeStart = 0
                shape.strokeEnd = trim
            }
        }
    }

    private func applyColor() {
        guard let content else { return }
        withoutImplicitAnimations {
            switch content {
            case .fill: shape.fillColor = resolved
            case .arc:  shape.strokeColor = resolved
            }
        }
    }

    private func restartAnimation() {
        shape.removeAnimation(forKey: Self.animationKey)
        guard let motion = motion ?? nil else { return }

        var animations: [CABasicAnimation] = []
        if let opacity = motion.opacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity.from
            fade.toValue = opacity.to
            animations.append(fade)
        }
        if let scale = motion.scale {
            let zoom = CABasicAnimation(keyPath: "transform.scale")
            zoom.fromValue = scale.from
            zoom.toValue = scale.to
            animations.append(zoom)
        }
        if let shift = motion.translationX {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = shift.from
            slide.toValue = shift.to
            animations.append(slide)
        }
        if motion.spins {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            animations.append(spin)
        }
        guard !animations.isEmpty else { return }

        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = motion.duration
        group.autoreverses = motion.autoreverses
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: motion.timing)
        // 无限循环本来跑不完；写上是防 CA 在某些时机（窗口重建等）提前收尾后把属性
        // 弹回 model 值。
        group.isRemovedOnCompletion = false
        shape.add(group, forKey: Self.animationKey)
    }
}

// MARK: - SwiftUI 薄壳

/// 一块挂着无限循环 CA 动画的形状。尺寸由调用方用 `.frame(...)` 给。
///
/// 颜色在 `context.environment` 里解析，所以深 / 浅切换（`\.colorScheme` 变化）
/// 会自动触发重新上色。
///
/// 这是底层逃生口 —— 常见形态优先用 `UDPulseHalo` / `UDBreathingDot`。
public struct UDMotionShape: View {
    let color: Color
    let content: UDMotionContent
    let motion: UDMotion?

    public init(color: Color, content: UDMotionContent, motion: UDMotion?) {
        self.color = color
        self.content = content
        self.motion = motion
    }

    public var body: some View {
        UDMotionRepresentable(color: color, content: content, motion: motion)
    }
}

/// 平台桥接层。保持 internal —— `UDMotionView` 是实现细节，不该进公开 API。
struct UDMotionRepresentable {
    let color: Color
    let content: UDMotionContent
    let motion: UDMotion?

    func resolvedColor(_ environment: EnvironmentValues) -> CGColor {
        let c = color.resolve(in: environment)
        return CGColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green),
                       blue: CGFloat(c.blue), alpha: CGFloat(c.opacity))
    }
}

#if canImport(AppKit)
extension UDMotionRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> UDMotionView { UDMotionView(frame: .zero) }

    func updateNSView(_ view: UDMotionView, context: Context) {
        view.configure(content: content, motion: motion,
                       color: resolvedColor(context.environment))
    }
}
#elseif canImport(UIKit)
extension UDMotionRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> UDMotionView { UDMotionView(frame: .zero) }

    func updateUIView(_ view: UDMotionView, context: Context) {
        view.configure(content: content, motion: motion,
                       color: resolvedColor(context.environment))
    }
}
#endif

// MARK: - 复用件

/// 呼吸光晕（状态点外圈的那圈扩散光）。`UDHostDot` / `UDStatusBadge` 共用。
///
/// 只画光晕，核心实心点由调用方自己画（常见是叠在 `ZStack` 里）。
public struct UDPulseHalo: View {
    let color: Color
    let diameter: CGFloat
    let peakOpacity: Double
    var scale: UDMotionRamp<CGFloat>
    var duration: TimeInterval

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 「减弱动态效果」打开时不画光晕（只占位），与 `UDBreathingDot` 一致；
    /// 以前只有 `UDHostDot` / `UDStatusBadge` 在外面自己判，直接用本组件的调用方照样一直闪。
    ///
    /// - Parameters:
    ///   - diameter: 光晕静止直径（动画在此基础上做 `scale`）。
    ///   - peakOpacity: 不透明度峰值，动画从它衰减到 0。注意取的是**实际**峰值 ——
    ///     若原实现是两层 `.opacity()` 相乘，这里要填相乘后的结果。
    public init(color: Color,
                diameter: CGFloat,
                peakOpacity: Double,
                scale: UDMotionRamp<CGFloat> = .init(from: 0.9, to: 1.1),
                duration: TimeInterval = 2.4) {
        self.color = color
        self.diameter = diameter
        self.peakOpacity = peakOpacity
        self.scale = scale
        self.duration = duration
    }

    public var body: some View {
        Group {
            if reduceMotion {
                Color.clear
            } else {
                UDMotionShape(
                    color: color,
                    content: .fill(cornerRadius: nil, size: nil),
                    motion: UDMotion(opacity: .init(from: peakOpacity, to: 0), scale: scale,
                                     duration: duration, autoreverses: true,
                                     timing: .easeInEaseOut)
                )
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }
}

/// 整点呼吸的状态点 —— 点**自身**在 `1 ↔ dimOpacity` 之间往复淡入淡出。
///
/// 与 `UDPulseHalo` 的区别：那个是在实心点外面画一圈扩散光晕（点本身不变），
/// 这个是整颗点在喘气。用于「订阅中 / 监听中」这类**长驻**指示（uTable 的 Redis
/// pub/sub 小绿点）—— 正因为长驻，更不能用 SwiftUI `.repeatForever`。
///
/// Reduce Motion 下常显不闪。
public struct UDBreathingDot: View {
    let color: Color
    let size: CGFloat
    let dimOpacity: Double
    let duration: TimeInterval
    let pulse: Bool

    /// - Parameters:
    ///   - dimOpacity: 暗态不透明度（亮态恒为 1）。
    ///   - pulse: false 时**根本不创建**平台视图，退化为静态圆点，零成本。
    public init(color: Color,
                size: CGFloat = 7,
                dimOpacity: Double = 0.35,
                duration: TimeInterval = 0.9,
                pulse: Bool = true) {
        self.color = color
        self.size = size
        self.dimOpacity = dimOpacity
        self.duration = duration
        self.pulse = pulse
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        Group {
            if pulse && !reduceMotion {
                UDMotionShape(
                    color: color,
                    content: .fill(cornerRadius: nil, size: nil),
                    motion: UDMotion(opacity: .init(from: 1, to: dimOpacity),
                                     duration: duration, autoreverses: true,
                                     timing: .easeInEaseOut)
                )
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}
