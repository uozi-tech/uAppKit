import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// uTerm DesignKit 色彩 token —— Claude Design 交付包 `Components.html` 的设计系统。
///
/// 与 `AppTheme.Palette`（系统语义色）和 `WS`（工作区**固定深色**）并存：`UD` 携带
/// 设计稿的**两套精确值（深 + 浅）**，通过动态 `NSColor` 随系统外观自动切换。
/// DesignKit 组件只读 `UD` token + 普通值输入，不依赖任何 domain model。
///
/// 命名空间用扁平静态属性（对齐 `WS` 的用法），并按需挂 `UD.Radius` / `UD.Space`
/// / `UD.Shadow` / 排版子组（见 `UDMetrics.swift` / `UDTypography.swift`）。
/// 标 `nonisolated` 让 token 能在任意上下文读取；`Color` 是 `Sendable`。
public enum UD {
    // MARK: - 动态色构造

    /// 一个外观无关的 sRGB 颜色描述（`Sendable`，可安全被动态 provider 闭包捕获）。
    public struct ColorSpec: Sendable, Equatable {
        public let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

        public nonisolated init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        #if canImport(AppKit)
        public nonisolated func nsColor() -> NSColor {
            NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        #elseif canImport(UIKit)
        public nonisolated func uiColor() -> UIColor {
            UIColor(red: r, green: g, blue: b, alpha: a)
        }
        #endif
        public nonisolated func color() -> Color {
            Color(.sRGB, red: r, green: g, blue: b, opacity: a)
        }
        /// `0xRRGGBB` + alpha。
        public nonisolated static func hex(_ h: UInt32, _ a: CGFloat = 1) -> ColorSpec {
            ColorSpec(r: CGFloat((h >> 16) & 0xFF) / 255,
                      g: CGFloat((h >> 8) & 0xFF) / 255,
                      b: CGFloat(h & 0xFF) / 255, a: a)
        }
        /// 白色叠加（深色面上的描边 / 文本透明度）。
        public nonisolated static func white(_ a: CGFloat) -> ColorSpec { ColorSpec(r: 1, g: 1, b: 1, a: a) }
        /// 黑色叠加（浅色面上的描边 / 文本 / 细填充透明度）。
        /// v2「填充即边界」：日间中性叠加一律纯黑基——旧石板蓝 slate(15,23,42) /
        /// 墨蓝 ink(20,24,33) 已废除（设计稿 v2 全局禁蓝调灰）。
        public nonisolated static func black(_ a: CGFloat) -> ColorSpec { ColorSpec(r: 0, g: 0, b: 0, a: a) }
    }

    /// 把 (深, 浅) 两个 spec 合成一个随系统外观切换的动态 `Color`。
    ///
    /// **不要在 `body` 里现调**：每次调用都新建一对 NSColor + Color，而 `Color` 的 `==`
    /// 落到底层 NSColor 的**实例同一性**上（同一实例 true / 值相同的两个实例 false）。
    /// 现算出来的颜色永远不等于上一帧的那个，SwiftUI「值没变就跳过子树」的快路径因此
    /// 永久失效，body 每帧重跑。固定配色一律提成 `static let`。
    public nonisolated static func dyn(_ dark: ColorSpec, _ light: ColorSpec) -> Color {
        #if canImport(AppKit)
        return Color(nsColor: dynNS(dark, light))
        #elseif canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return (isDark ? dark : light).uiColor()
        })
        #else
        return dark.color()
        #endif
    }

    #if canImport(AppKit)
    /// `bestMatch` 的候选表。provider 闭包对**每一次**颜色解析都会跑一遍，
    /// 数组不该在里面现建。
    private nonisolated static let appearanceCandidates: [NSAppearance.Name] = [.aqua, .darkAqua]

    /// `dyn` 的 `NSColor` 版 —— 供 AppKit 视图（SQL 编辑器的 NSTextView / 行号栏等）
    /// 直接消费，同样随系统外观切换。
    public nonisolated static func dynNS(_ dark: ColorSpec, _ light: ColorSpec) -> NSColor {
        // 两个分支的 NSColor 在闭包外建好、由闭包捕获：每次解析只剩一次 bestMatch
        // 加一次三目，不再新建颜色对象。
        let darkNS = dark.nsColor()
        let lightNS = light.nsColor()
        return NSColor(name: nil) { appearance in
            // 必须走 bestMatch，不能写成 `appearance.name == .darkAqua`：VibrantDark
            // 外观（菜单 / popover / 系统浮层）的 name 是 NSAppearanceNameVibrantDark，
            // 比 name 会把深色浮层判成浅色。
            appearance.bestMatch(from: appearanceCandidates) == .darkAqua ? darkNS : lightNS
        }
    }
    #endif

    // MARK: - 表面 Surfaces（组件库调色板 · Ant Design 预设：body / card / raised / modal / popover）
    // 深色：layout #000 → container #141414 → elevated #1F1F1F → modal #262626。
    // 日间：画布与 panel 纯白，panelHi #F0F0F0，窗口外页底 #F5F5F5。
    public nonisolated static let bg         = dyn(.hex(0x121212), .hex(0xFFFFFF))
    public nonisolated static let panel      = dyn(.hex(0x1C1C1E), .hex(0xFFFFFF))
    public nonisolated static let panelHi    = dyn(.hex(0x262628), .hex(0xF0F0F0))
    /// 悬停填充。**半透明叠加**而不是实色：调色板的实色值（深 #262626 / 浅 #F0F0F0）与
    /// overlayHi、border、panelHi、tabActive 撞同一个值——模态里悬停看不见、带描边的卡片悬停时
    /// 填成边框色而丢边、悬停的 tab 和激活 tab 分不出。叠加在 panel 上与调色板几乎同值，
    /// 叠在任何更亮的面上仍可见。带描边的元素悬停时还要把描边提到 `borderHi`。
    public nonisolated static let panelHover = dyn(.white(0.08), .black(0.04))
    /// 窗口外页底（设计稿 --u-page-bg，仅日间与画布区分）。
    // 2026-11-17 暗色层级（uGit 对比度审计后用户定）：页底不用纯黑（近白字眩光、与 macOS 深色窗口不一致），
    // 各层亮度拉开、越浮越亮：page #121212 → card / panel #1C1C1E → overlay #2A2A2C → overlayHi #323234。
    public nonisolated static let pageBg     = dyn(.hex(0x121212), .hex(0xF5F5F5))
    /// 卡片面（侧栏 / AI 助手面板 / 状态栏 / 连接卡）——调色板里 card 与 panel 同为 container。
    public nonisolated static let card       = dyn(.hex(0x1C1C1E), .hex(0xFFFFFF))
    /// 浮层实体面（下拉 / 菜单 / popover）。浅色用纯白面板。
    public nonisolated static let overlay    = dyn(.hex(0x2A2A2C), .hex(0xFFFFFF))
    /// 模态实体面（指标卡 / 菜单栏面板）。
    public nonisolated static let overlayHi  = dyn(.hex(0x323234), .hex(0xFFFFFF))

    // MARK: - 描边 Stroke（深=白叠加 / 浅：border 黑 6.5%、borderHi 实色）
    // v2 描边只允许四处：分区 hairline / 浮层 / 白底列表容器 / 状态描边（聚焦环·错误·拖放·同步中）。
    // 日间 border 不用调色板的 #F0F0F0：v3.3 的卡内分栏全靠这条 1pt 线，#F0F0F0 压在白卡上
    // 几乎看不见（实测截图接缝处只有 244–247 的灰，用户反馈「缺分割线」）。
    // 2026-11-06 又从黑 9% / 白 12% 调到黑 6.5% / 白 9%（用户反馈「所有的线都太显眼」）：
    // 黑 6.5% 落在白底 ≈ #EEEEEE，仍比 panelHi #F0F0F0 深一档、接缝处可辨。再淡就回到看不见。
    public nonisolated static let border     = dyn(.white(0.09), .black(0.065))
    public nonisolated static let borderHi   = dyn(.white(0.20), .hex(0xE0E0E0))

    // MARK: - 文本 Text（深=白叠加 85 / 65 / 55 / 38% / 浅=实色）
    // text2 正文层 · text3 次要信息层 · text4 仅装饰 / 结构层（分隔线 / 行号 / 禁用图标）。
    // 2026-11-17：深色 text3 由 45% 提到 55%（对齐 macOS secondaryLabel，在浮层上也 ≥4.5:1），
    // text4 由 25% 提到 38%（实际常被拿来写计数 / 日期，25% 只有约 2.3:1）。
    public nonisolated static let text       = dyn(.hex(0xD9D9D9), .hex(0x1F1F1F))
    public nonisolated static let text2      = dyn(.white(0.65), .hex(0x595959))   // 正文层
    public nonisolated static let text3      = dyn(.white(0.55), .hex(0x8C8C8C))   // 次要信息层
    public nonisolated static let text4      = dyn(.white(0.38), .hex(0xBFBFBF))   // 仅装饰 / 结构层

    // MARK: - 次按钮 Button2（调色板 button2 · default / hover / pressed）
    // 深色白叠加 8 / 12 / 18%；日间黑叠加 4 / 6 / 15%——落在白底上正是调色板的
    // #F5F5F5 / #F0F0F0 / #D9D9D9，但不会像实色那样在 #F5F5F5 画布（pageBg）上隐形。
    public nonisolated static let button2        = dyn(.white(0.08), .black(0.04))
    public nonisolated static let button2Hover   = dyn(.white(0.12), .black(0.06))
    public nonisolated static let button2Pressed = dyn(.white(0.18), .black(0.15))

    // MARK: - 强调 Accent（可切换；见 AccentColor / AccentState。getter 同步读 selected →
    // SwiftUI body 求值期访问被 Observation 追踪 → 切色全局自动重渲染。默认蓝 = 原手调值。）
    //
    // 每个强调色的 10 个槽位在进程启动时一次性建好并缓存，getter 只查表、返回**同一个**
    // `Color` 实例。这不是省几次构造那么简单：`Color` 的 `==` 落到底层 `NSColor` 的
    // **实例同一性**上（同一实例 true / 值相同的两个实例 false），getter 每次新建就意味着
    // 任何把 accent 存进 view value 的视图「这一帧的值永远不等于上一帧」，SwiftUI
    // 「值没变就跳过子树」的快路径被永久废掉，body 每帧重跑。
    //
    // 缓存的是「哪个 Color 对象」，不是「解析后的 RGBA」：表里存的仍是 `dyn` 产出的动态
    // Color，底层 provider 照旧在每次绘制时按当前外观解析，深浅色切换不受影响。

    /// 一个强调色的全部槽位，深浅仍由各 `Color` 自己的动态 provider 决定。
    ///
    /// 用 `final class` 而不是 `struct`：查表结果每读一次就要复制一遍，10 个 `Color`
    /// 字段意味着 10 对 retain/release；引用类型只需一次。全部字段 `let` + `Color`
    /// 是 `Sendable`，故无需 `@unchecked`。
    final class AccentPalette: Sendable {
        let accent: Color, hover: Color, ink: Color, soft: Color, pressed: Color
        let tint: Color, tintHover: Color, tintPressed: Color, tintDisabled: Color
        /// 导航类选中行底（见下方「行态」段的 `rowSelected`）。
        let rowSelected: Color

        init(_ a: AccentColor) {
            accent  = UD.dyn(a.accentSpec(dark: true),  a.accentSpec(dark: false))
            hover   = UD.dyn(a.hoverSpec(dark: true),   a.hoverSpec(dark: false))
            ink     = UD.dyn(a.inkSpec(dark: true),     a.inkSpec(dark: false))
            soft    = UD.dyn(a.softSpec(dark: true),    a.softSpec(dark: false))
            pressed = UD.dyn(a.pressedSpec(dark: true), a.pressedSpec(dark: false))
            func tinted(_ spec: (Bool) -> UD.ColorSpec, _ alpha: CGFloat) -> Color {
                UD.dyn(spec(true).withAlpha(alpha), spec(false).withAlpha(alpha))
            }
            // v2「填充即边界」accent tint 阶（两主题通用）：选中 / 主操作底 14% · 禁用底 7%；
            // hover 取 hover 色 22%、按下取 pressed 色 19%（调色板 base · hover · pressed 逐级变亮）。
            tint = tinted(a.accentSpec, 0.14)
            tintHover = tinted(a.hoverSpec, 0.22)
            tintPressed = tinted(a.pressedSpec, 0.19)
            tintDisabled = tinted(a.accentSpec, 0.07)
            // 选中行底：深 20% / 日 12%（2026-11-17 深色由 14% 提到 20%：14% 在深底上与面几乎分不出）。
            rowSelected = UD.dyn(a.accentSpec(dark: true).withAlpha(0.20),
                                 a.accentSpec(dark: false).withAlpha(0.12))
        }
    }

    /// 全色查表。按 `allCases` 建，新增强调色无需改这里。
    private nonisolated static let accentPalettes: [AccentColor: AccentPalette] =
        Dictionary(uniqueKeysWithValues: AccentColor.allCases.map { ($0, AccentPalette($0)) })

    /// 表由 `allCases` 建，每个 case 必有条目；这个兜底只是为了不写 `!`。
    private nonisolated static let accentPaletteFallback = AccentPalette(.blue)

    /// 查表本身：同一强调色永远返回同一个 `AccentPalette`（因而同一批 `Color` 实例）。
    /// 与 `AccentState.shared` 解耦，单测可直接按强调色查，不必改开发机上的真实选色。
    nonisolated static func accentPalette(for accent: AccentColor) -> AccentPalette {
        accentPalettes[accent] ?? accentPaletteFallback
    }

    /// 同步读 `selected` —— Observation 依赖照旧在此注册，切换强调色仍全局生效。
    @MainActor private static var accentPalette: AccentPalette {
        accentPalette(for: AccentState.shared.selected)
    }

    @MainActor public static var accent: Color { accentPalette.accent }
    @MainActor public static var accentHover: Color { accentPalette.hover }
    @MainActor public static var accentInk: Color { accentPalette.ink }
    @MainActor public static var accentSoft: Color { accentPalette.soft }
    @MainActor public static var accentPressed: Color { accentPalette.pressed }

    @MainActor public static var accentTint: Color { accentPalette.tint }
    @MainActor public static var accentTintHover: Color { accentPalette.tintHover }
    @MainActor public static var accentTintPressed: Color { accentPalette.tintPressed }
    @MainActor public static var accentTintDisabled: Color { accentPalette.tintDisabled }

    /// Nonisolated default accent (fixed blue, still dark/light dynamic) for use
    /// as a **default parameter / stored-property value** in nonisolated inits.
    /// uTable builds in Swift 5 mode, where default-argument expressions are
    /// nonisolated and can't reference the `@MainActor` `accent` getter. uTable
    /// ships no accent switcher, so the resolved value equals `accent` at runtime.
    /// Explicit callers may still pass the dynamic `UD.accent`.
    public nonisolated static let accentDefault = dyn(AccentColor.blue.accentSpec(dark: true),
                                               AccentColor.blue.accentSpec(dark: false))

    /// AI 介入固定紫（设计稿 `#a78bfa`，§6）。与连接强调色刻意区分；深浅同值。
    /// 快捷命令「AI 介入」徽标 / 开关 / 闪标 / 图标染色专用。
    public nonisolated static let aiAccent = ColorSpec.hex(0xA78BFA).color()

    // 备选强调色（设计稿固定 macOS 系统色，深浅同值）。
    public nonisolated static let accentViolet = ColorSpec.hex(0xBF5AF2).color()   // 雾紫
    public nonisolated static let accentSage   = ColorSpec.hex(0x30D158).color()   // 鼠尾草
    public nonisolated static let accentGold   = ColorSpec.hex(0xFFD60A).color()   // 黯金
    public nonisolated static let accentRose   = ColorSpec.hex(0xFF5A5A).color()   // 藕薇

    // MARK: - 语义状态 Semantic（调色板 success / warning / error / info，取 Ant 色阶）
    // info 与主色同为蓝。caution（断开）不并进 warning：「连接中」与「断开」必须分得出，
    // 取 Ant 橙色阶（深 orange-6 暗色版 / 浅 orange-6）。状态点 / 徽章 / danger 态等全经此 token。
    // 2026-11-17：深色语义色提亮（叠在自己 14–22% 的底上做文字也要 ≥4.5:1）。
    public nonisolated static let success = dyn(.hex(0x6ABE39), .hex(0x52C41A))   // 已连接
    public nonisolated static let warning = dyn(.hex(0xD89614), .hex(0xFAAD14))   // 连接中
    public nonisolated static let caution = dyn(.hex(0xE88B2A), .hex(0xFA8C16))   // 断开
    public nonisolated static let danger  = dyn(.hex(0xF07070), .hex(0xFF4D4F))   // 失败 / 危险
    public nonisolated static let info    = dyn(.hex(0x4C9BF5), .hex(0x1677FF))   // 信息
    /// danger 的 hover 色（危险按钮悬停时的文字）。
    public nonisolated static let dangerHover = dyn(.hex(0xF28B82), .hex(0xFF7875))

    // MARK: - 文件夹 / 图标色 Folder & Icon（设计稿 --u-folder-1/2 · --u-icon-teal）
    // 暗夜保持原样（鲜艳双色蓝 + 青）；日间文件夹换 macOS Finder 风格鲜亮饱和蓝
    // （旧低饱和雾霾蓝看起来发灰），符号链接转向箭头仍柔青。
    public nonisolated static let folder1    = dyn(.hex(0x5B8FD6), .hex(0x2B86E6))   // 文件夹背片（深蓝）
    public nonisolated static let folder2    = dyn(.hex(0x79A9E8), .hex(0x4CA7F8))   // 文件夹前片（亮蓝，主填充）
    public nonisolated static let folderArrow = dyn(.hex(0x0E2742), .hex(0xFFFFFF))  // 文件夹「返回上级」箭头
    public nonisolated static let iconTeal   = dyn(.hex(0x2DD4BF), .hex(0x0FB6AC))   // 符号链接转向箭头（日间 = oklch(0.70 0.12 188)）

    // MARK: - 文档图标色 Doc（设计稿 --u-doc-bg/line/fold/detail）
    // 暗夜：白叠加纸面（半透叠在深底）。日间：纯白纸 + 1pt 暖中性灰描边 + 暖白右上折角 +
    // 暖灰内文线——取代旧「灰色纸片」（doc.fill 填 text4），且不发蓝（与暖中性白底统一）。
    public nonisolated static let docBg     = dyn(.white(0.09), .hex(0xFFFFFF))   // 纸张填充
    public nonisolated static let docLine   = dyn(.white(0.26), .hex(0xC9C7C4))   // 描边（纸 + 折角共用）
    public nonisolated static let docFold   = dyn(.white(0.16), .hex(0xEEEDEA))   // 右上折角
    public nonisolated static let docDetail = dyn(.white(0.32), .hex(0xA8A6A3))   // 内部文本线

    // MARK: - 代码区 Code（设计稿 --u-term-bg · --u-syn-*，2026-07 评审 §4）
    // 代码面板随主题，不再强制深色：termBg 深 #000000（调色板 term）/ 浅 #FFFFFF。
    // 语法高亮双套：深 = VSCode Dark 系，浅 = GitHub Light 系。spec 常量供
    // SwiftUI（`dyn`）与 AppKit（`dynNS`，SQL 编辑器 NSTextView）两侧共用。
    public enum CodeSpec {
        public nonisolated static let bg:      (dark: ColorSpec, light: ColorSpec) = (.hex(0x000000), .hex(0xFFFFFF))
        public nonisolated static let kw:      (dark: ColorSpec, light: ColorSpec) = (.hex(0xC586C0), .hex(0x8250DF))
        public nonisolated static let fn:      (dark: ColorSpec, light: ColorSpec) = (.hex(0x9CDCFE), .hex(0x0550AE))
        public nonisolated static let str:     (dark: ColorSpec, light: ColorSpec) = (.hex(0xCE9178), .hex(0xA8410B))
        public nonisolated static let num:     (dark: ColorSpec, light: ColorSpec) = (.hex(0xB5CEA8), .hex(0x0A7D2C))
        public nonisolated static let comment: (dark: ColorSpec, light: ColorSpec) = (.hex(0x6A9955), .hex(0x6A737D))
        public nonisolated static let op:      (dark: ColorSpec, light: ColorSpec) = (.hex(0xD4D4D4), .hex(0x3B3B40))
    }
    public nonisolated static let termBg     = dyn(CodeSpec.bg.dark, CodeSpec.bg.light)
    public nonisolated static let synKw      = dyn(CodeSpec.kw.dark, CodeSpec.kw.light)
    public nonisolated static let synFn      = dyn(CodeSpec.fn.dark, CodeSpec.fn.light)
    public nonisolated static let synStr     = dyn(CodeSpec.str.dark, CodeSpec.str.light)
    public nonisolated static let synNum     = dyn(CodeSpec.num.dark, CodeSpec.num.light)
    public nonisolated static let synComment = dyn(CodeSpec.comment.dark, CodeSpec.comment.light)
    public nonisolated static let synOp      = dyn(CodeSpec.op.dark, CodeSpec.op.light)

    // MARK: - 输入底 Input（设计稿 v2 --u-input-bg：输入框改淡灰填充、无边）
    // 暗夜：白叠加 6%（DesignKit 清单 3.5%→6%）。日间：黑叠加 5%（边界由填充承担）。
    public nonisolated static let inputBg     = dyn(.white(0.06),  .black(0.05))
    public nonisolated static let inputBgSoft = dyn(.white(0.045), .black(0.04))

    // MARK: - 输入框 Input field（1.22.9 起 DesignKit 自己的输入控件用这一对）
    // 日间不再用淡灰底：白底 + 一圈细边（黑 12%），放在白卡片和灰画布上都分得清。
    // 暗夜不变：白叠加 6% 填充承担边界、闲置无边。聚焦仍是 accent 描边 + 3pt 柔环（控件可用 `showsFocusRing` 关掉）。
    // `inputBg` 保留原值——各 app 里直接拿它铺底、没有描边的自绘输入区改成白底就看不见了。
    public nonisolated static let inputFill   = dyn(.white(0.06),  .hex(0xFFFFFF))
    public nonisolated static let inputBorder = dyn(.white(0),     .black(0.12))

    // MARK: - 行态 Row / Tab（uTable.dc.html v2 --u-row-hover / --u-row-sel / --u-tab-active）
    // rowHover = 中性 hover（日 黑4%）。导航类选中态（列表行 / pill / ⌘K 行 / 底部导航）
    // = accent 填充（深 14% / 日 12%，调色板 sel）+ accent 文字图标（清单 §4「驾驶舱」样式），
    // 无 accent 描边。选中底与文字同属强调色：1.21.0 起 `rowSelected` 跟随 `AccentState`，
    // 与 `UD.accent*` 一样从缓存的 `AccentPalette` 取（同一强调色返回同一实例，理由见上）。
    public nonisolated static let rowHover    = dyn(.white(0.035), .black(0.04))

    /// 导航类选中行底，跟随用户选的强调色（深 14% / 日 12%）。
    /// 1.21.0 前是固定蓝的 `nonisolated static let`；nonisolated 上下文请改用 `rowSelectedDefault`。
    @MainActor public static var rowSelected: Color { accentPalette.rowSelected }

    /// Nonisolated default row-selection fill (fixed blue, still dark/light dynamic;
    /// 14% dark / 12% light) for use as a **default parameter / stored-property value**
    /// in nonisolated contexts — e.g. Swift 5 language mode clients such as uTable,
    /// where default-argument expressions are nonisolated and can't reference the
    /// `@MainActor` `rowSelected` getter. This is exactly the value `rowSelected` had
    /// before 1.21.0; apps without an accent switcher see no difference at runtime.
    /// Views that should follow the user's accent must read `UD.rowSelected` instead.
    public nonisolated static let rowSelectedDefault = dyn(AccentColor.blue.accentSpec(dark: true).withAlpha(0.20),
                                                    AccentColor.blue.accentSpec(dark: false).withAlpha(0.12))
    /// 激活 Tab 底（日间 = panelHi；暗夜保持与编辑器正文同底的无缝拼接 = bg 深色）。
    public nonisolated static let tabActive   = dyn(.hex(0x000000), .hex(0xF0F0F0))

    // MARK: - 自适应灰阶 uw-*（uTable.dc.html v2 --uw-*：深=白叠加 / 浅=黑叠加）
    // v2 整体加深一档（变量名保留旧 α）：灰底控件的边界全靠填充，禁再叠描边。
    public nonisolated static let uw02 = dyn(.white(0.035), .black(0.045))   // hover / 斑马行
    public nonisolated static let uw03 = dyn(.white(0.045), .black(0.055))   // chip / 胶囊
    public nonisolated static let uw04 = dyn(.white(0.055), .black(0.065))   // 控件底（次按钮 / 输入框级）
    public nonisolated static let uw05 = dyn(.white(0.065), .black(0.075))   // 进度轨道
    public nonisolated static let uw06 = dyn(.white(0.075), .black(0.085))   // 控件 hover 加深档
    public nonisolated static let uw08 = dyn(.white(0.10),  .black(0.11))    // 未选中 checkbox
    public nonisolated static let uw10 = dyn(.white(0.12),  .black(0.13))    // Switch 关态轨道

    // 旧 fill 系列 → v2 uw ramp 的别名（渐进迁移；新代码请直接用 uw*）。
    public nonisolated static let fillFaint = uw03   // 卡片 / 气泡静态底
    public nonisolated static let fillSoft  = uw05   // 选中段 / 代码片
    public nonisolated static let fillMed   = uw08   // 进度槽等功能轨道

    // MARK: - 遥测分类色 Telemetry（状态栏 / 指标卡，深浅各一套）
    public nonisolated static let mPlatform = dyn(.hex(0x409CFF), .hex(0x007AFF))   // 平台
    public nonisolated static let mEndpoint = dyn(.hex(0x9AA7B5), .hex(0x6B7681))   // endpoint / 时间戳
    public nonisolated static let mUptime   = dyn(.hex(0x30D158), .hex(0x34C759))   // 运行时长
    public nonisolated static let mLoad     = dyn(.hex(0xFF5F7E), .hex(0xFF3B30))   // 负载
    public nonisolated static let mCPU      = dyn(.hex(0x3FD6C0), .hex(0x1FC0A8))   // CPU
    public nonisolated static let mMem      = dyn(.hex(0xFFD60A), .hex(0xFFAA00))   // 内存
    public nonisolated static let mDisk     = dyn(.hex(0xFF9F0A), .hex(0xFF8A00))   // 磁盘
}
