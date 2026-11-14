import Foundation
import SwiftUI

/// # UIcon — uTable 自绘图标引擎（design ↔ 实现对齐 · 路线 C）
///
/// 设计稿 `uTable.dc.html` 使用一整套自绘的 1.1–1.4px 细描边 SVG 图标，SF Symbols
/// 无法复刻其字重与造型。`UIcon` 把设计稿里**原样的 SVG 元素**（rect / circle /
/// ellipse / path）渲染成一个 `Shape`：每个子路径先按自身 stroke 宽度描边为轮廓，
/// 再整体缩放到目标尺寸。因为最终是一个可填充的 `Path`，`.foregroundStyle(...)`
/// 天然生效（等价于 SVG 的 `currentColor`），且矢量无损缩放。
///
/// 用法与 `Image(systemName:)` 对齐：
/// ```swift
/// UIcon(.navWorkspace, size: 17)
///     .foregroundStyle(active ? UD.accent : UD.text3)
/// ```
public enum UIconEngine {}

// MARK: - Glyph model（1:1 对应设计稿的 SVG 元素）

/// 一个图标：`box` 是（正方形）viewBox 边长，`elements` 是其中的绘制元素。
public struct UIconGlyph: Hashable, Sendable {
    let box: CGFloat
    let elements: [UIconElement]

    public init(_ box: CGFloat, _ elements: [UIconElement]) {
        self.box = box
        self.elements = elements
    }
}

/// 单个绘制元素。`filled == true` 走填充（SVG `fill="currentColor"`），否则按
/// `width` 描边（SVG `stroke`）。`cap` / `join` 对应 stroke-linecap / linejoin。
public struct UIconElement: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case path(String)                       // <path d="…">
        case rect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat)
        case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
        case ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat)
    }

    let kind: Kind
    let width: CGFloat
    let filled: Bool
    let cap: CGLineCap
    let join: CGLineJoin

    // 便捷构造器 —— 对齐 SVG 属性默认值。
    static func path(_ d: String, w: CGFloat = 1.2, filled: Bool = false,
                     cap: CGLineCap = .butt, join: CGLineJoin = .miter) -> UIconElement {
        UIconElement(kind: .path(d), width: w, filled: filled, cap: cap, join: join)
    }
    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                     r: CGFloat = 0, sw: CGFloat = 1.2) -> UIconElement {
        UIconElement(kind: .rect(x: x, y: y, w: w, h: h, r: r), width: sw, filled: false, cap: .butt, join: .miter)
    }
    static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, sw: CGFloat = 1.1) -> UIconElement {
        UIconElement(kind: .circle(cx: cx, cy: cy, r: r), width: sw, filled: false, cap: .butt, join: .miter)
    }
    static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, sw: CGFloat = 1) -> UIconElement {
        UIconElement(kind: .ellipse(cx: cx, cy: cy, rx: rx, ry: ry), width: sw, filled: false, cap: .butt, join: .miter)
    }
}

// MARK: - Shape 渲染

/// 把一个 `UIconGlyph` 渲染为可填充 `Path`：描边子路径先转轮廓，再统一缩放。
///
/// 按**墨迹**居中，而不是按 viewBox：设计稿里不少字形在 viewBox 里本就偏一侧
/// （`toolUndo` 偏右 1.25pt、`copyRow` 右下各 1pt），原样摆进等大方钮就显得歪。
/// 缩放比仍按 viewBox 算，所以字形之间的相对大小与描边粗细不变。
public struct UIconShape: Shape {
    let glyph: UIconGlyph

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / glyph.box
        // 轮廓只在 viewBox 坐标系里算一次（见 `UIconEngine.outline`），这里只做变换。
        let outline = UIconEngine.outline(for: glyph)
        let ink = outline.boundingRect
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -ink.midX, y: -ink.midY)
        return outline.applying(transform)
    }
}

/// 与 `Image(systemName:)` 同构的便捷视图：固定 `size × size`，颜色由
/// `.foregroundStyle(...)` 决定。
public struct UIcon: View {
    let glyph: UIconGlyph
    var size: CGFloat = 15

    public init(_ glyph: UIconGlyph, size: CGFloat = 15) {
        self.glyph = glyph
        self.size = size
    }

    public var body: some View {
        UIconShape(glyph: glyph)
            .frame(width: size, height: size)
    }
}

/// 图标引用：既可以是 SF Symbol（通用控件保留），也可以是自绘字形（设计独有）。
/// 供那些「一处渲染、图标按数据变化」的视图（如对象树行、标签、工具栏）统一承载。
public enum UIconRef: Equatable {
    case sf(String)
    case glyph(UIconGlyph)
}

/// 渲染 `UIconRef`：SF 用字号+字重，glyph 用 `size`。颜色由外层 `.foregroundStyle`。
///
/// `box` 非空时 SF 符号走 `USymbol`：墨迹长边超出 `box` 的等比缩进去、并按墨迹居中
/// ——用于一排等大图标钮。默认 `nil`，与文字同行时仍按字号排版。
public struct UIconRefView: View {
    let ref: UIconRef
    var size: CGFloat = 15
    var weight: Font.Weight = .regular
    var box: CGFloat? = nil

    public init(_ ref: UIconRef, size: CGFloat = 15, weight: Font.Weight = .regular, box: CGFloat? = nil) {
        self.ref = ref
        self.size = size
        self.weight = weight
        self.box = box
    }

    public var body: some View {
        switch ref {
        case let .sf(name) where box != nil:
            USymbol(name, size: size, weight: weight, box: box)
        case let .sf(name):
            Image(systemName: name).font(.system(size: size, weight: weight))
        case let .glyph(g):
            UIcon(g, size: size)
        }
    }
}

// MARK: - 轮廓缓存

public extension UIconEngine {
    /// 字形在 viewBox 坐标系里的最终轮廓（描边已转成可填充路径），**按字形缓存**。
    ///
    /// `Shape.path(in:)` 每次布局、每次重绘都会被调用，而这里的两步都不便宜：
    /// `d` 字符串要走一遍迷你 SVG 解析器，描边还要 `strokedPath` 求轮廓。字形是
    /// 编译期常量、数量有限（一个应用几十个图标），所以直接全量缓存，`path(in:)`
    /// 只剩一次仿射变换。
    static func outline(for glyph: UIconGlyph) -> Path {
        outlineCacheLock.lock()
        defer { outlineCacheLock.unlock() }
        if let cached = outlineCache[glyph] { return cached }
        var out = Path()
        for el in glyph.elements {
            let raw = subpath(for: el.kind)
            if el.filled {
                out.addPath(raw)
            } else {
                // 在原生 viewBox 坐标系内描边（宽度随后随整体缩放，保持比例）。
                out.addPath(raw.strokedPath(
                    StrokeStyle(lineWidth: el.width, lineCap: el.cap, lineJoin: el.join)
                ))
            }
        }
        outlineCache[glyph] = out
        return out
    }
}

/// `path(in:)` 可能在非主线程被调用（SwiftUI 渲染），缓存加锁。
private let outlineCacheLock = NSLock()
nonisolated(unsafe) private var outlineCache: [UIconGlyph: Path] = [:]

// MARK: - 元素 → Path

public extension UIconEngine {
    static func subpath(for kind: UIconElement.Kind) -> Path {
        switch kind {
        case let .path(d):
            return UIconPathParser.parse(d)
        case let .rect(x, y, w, h, r):
            let rc = CGRect(x: x, y: y, width: w, height: h)
            return r > 0 ? Path(roundedRect: rc, cornerRadius: r) : Path(rc)
        case let .circle(cx, cy, r):
            return Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        case let .ellipse(cx, cy, rx, ry):
            return Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        }
    }
}

// MARK: - 迷你 SVG path 解析器

/// 支持设计稿用到的 `d` 子集：M m L l H h V v C c S s Q q T t A a Z z。
/// 三次/二次贝塞尔用原生 `addCurve`/`addQuadCurve`（精确）；椭圆弧 A/a 按端点→
/// 圆心换算后采样为折线（图标尺寸下视觉无损）。坐标 y 轴与 SVG 一致（向下为正）。
public enum UIconPathParser {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var scanner = TokenScanner(d)
        var cur = CGPoint.zero          // 当前点
        var start = CGPoint.zero        // 子路径起点
        var prevCtrl: CGPoint?          // 上一段三次控制点（S）
        var prevQCtrl: CGPoint?         // 上一段二次控制点（T）
        var lastCmd: Character = " "

        while let cmd = scanner.nextCommand() {
            let rel = cmd.isLowercase
            switch Character(cmd.uppercased()) {
            case "M":
                var first = true
                while scanner.hasNumber {
                    let p = scanner.point(rel: rel, from: cur)
                    if first { path.move(to: p); start = p; first = false }
                    else { path.addLine(to: p) }
                    cur = p
                }
                prevCtrl = nil; prevQCtrl = nil
            case "L":
                while scanner.hasNumber {
                    let p = scanner.point(rel: rel, from: cur)
                    path.addLine(to: p); cur = p
                }
                prevCtrl = nil; prevQCtrl = nil
            case "H":
                while scanner.hasNumber {
                    let x = scanner.num() + (rel ? cur.x : 0)
                    let p = CGPoint(x: x, y: cur.y)
                    path.addLine(to: p); cur = p
                }
                prevCtrl = nil; prevQCtrl = nil
            case "V":
                while scanner.hasNumber {
                    let y = scanner.num() + (rel ? cur.y : 0)
                    let p = CGPoint(x: cur.x, y: y)
                    path.addLine(to: p); cur = p
                }
                prevCtrl = nil; prevQCtrl = nil
            case "C":
                while scanner.hasNumber {
                    let c1 = scanner.point(rel: rel, from: cur)
                    let c2 = scanner.point(rel: rel, from: cur)
                    let end = scanner.point(rel: rel, from: cur)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    prevCtrl = c2; cur = end
                }
                prevQCtrl = nil
            case "S":
                while scanner.hasNumber {
                    let c1 = reflect(prevCtrl, about: cur, lastWasCubic: lastCmd == "C" || lastCmd == "S")
                    let c2 = scanner.point(rel: rel, from: cur)
                    let end = scanner.point(rel: rel, from: cur)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    prevCtrl = c2; cur = end
                }
                prevQCtrl = nil
            case "Q":
                while scanner.hasNumber {
                    let c = scanner.point(rel: rel, from: cur)
                    let end = scanner.point(rel: rel, from: cur)
                    path.addQuadCurve(to: end, control: c)
                    prevQCtrl = c; cur = end
                }
                prevCtrl = nil
            case "T":
                while scanner.hasNumber {
                    let c = reflect(prevQCtrl, about: cur, lastWasCubic: lastCmd == "Q" || lastCmd == "T")
                    let end = scanner.point(rel: rel, from: cur)
                    path.addQuadCurve(to: end, control: c)
                    prevQCtrl = c; cur = end
                }
                prevCtrl = nil
            case "A":
                while scanner.hasNumber {
                    let rx = scanner.num(), ry = scanner.num()
                    let rot = scanner.num()
                    let large = scanner.flag(), sweep = scanner.flag()
                    let end = scanner.point(rel: rel, from: cur)
                    appendArc(&path, from: cur, to: end, rx: rx, ry: ry,
                              rotationDeg: rot, largeArc: large, sweep: sweep)
                    cur = end
                }
                prevCtrl = nil; prevQCtrl = nil
            case "Z":
                path.closeSubpath(); cur = start
                prevCtrl = nil; prevQCtrl = nil
            default:
                break
            }
            lastCmd = Character(cmd.uppercased())
        }
        return path
    }

    private static func reflect(_ ctrl: CGPoint?, about p: CGPoint, lastWasCubic: Bool) -> CGPoint {
        guard let c = ctrl, lastWasCubic else { return p }
        return CGPoint(x: 2 * p.x - c.x, y: 2 * p.y - c.y)
    }

    /// 端点式椭圆弧 → 圆心式，采样为折线。
    private static func appendArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint,
                                  rx rxIn: CGFloat, ry ryIn: CGFloat,
                                  rotationDeg: CGFloat, largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 { path.addLine(to: p1); return }

        let phi = rotationDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy

        // 半径修正。
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }

        let rx2 = rx * rx, ry2 = ry * ry, x1p2 = x1p * x1p, y1p2 = y1p * y1p
        var num = rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2
        let den = rx2 * y1p2 + ry2 * x1p2
        if num < 0 { num = 0 }
        var coef = (den == 0) ? 0 : sqrt(num / den)
        if largeArc == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)

        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(max(-1, min(1, len == 0 ? 1 : dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let steps = max(4, Int(ceil(abs(dTheta) / (.pi / 12))))   // ≤15° 每段
        for i in 1...steps {
            let t = theta1 + dTheta * CGFloat(i) / CGFloat(steps)
            let ex = cosP * rx * cos(t) - sinP * ry * sin(t) + cx
            let ey = sinP * rx * cos(t) + cosP * ry * sin(t) + cy
            path.addLine(to: CGPoint(x: ex, y: ey))
        }
    }
}

// MARK: - 数字/命令扫描

private struct TokenScanner {
    private let chars: [Character]
    private var i = 0

    public init(_ s: String) { chars = Array(s) }

    private mutating func skipSep() {
        while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" {
            i += 1
        }
    }

    mutating func nextCommand() -> Character? {
        skipSep()
        guard i < chars.count else { return nil }
        let c = chars[i]
        if c.isLetter { i += 1; return c }
        return nil          // 隐式重复命令时不消费，交由调用方按 hasNumber 继续
    }

    var hasNumber: Bool {
        var j = i
        while j < chars.count, chars[j] == " " || chars[j] == "," || chars[j] == "\n" || chars[j] == "\t" || chars[j] == "\r" { j += 1 }
        guard j < chars.count else { return false }
        let c = chars[j]
        return c.isNumber || c == "-" || c == "+" || c == "."
    }

    mutating func num() -> CGFloat {
        skipSep()
        var s = ""
        var seenDot = false, seenExp = false
        while i < chars.count {
            let c = chars[i]
            if c.isNumber { s.append(c); i += 1 }
            else if c == "." && !seenDot && !seenExp { seenDot = true; s.append(c); i += 1 }
            else if (c == "-" || c == "+") && (s.isEmpty || s.last == "e" || s.last == "E") { s.append(c); i += 1 }
            else if (c == "e" || c == "E") && !seenExp { seenExp = true; s.append(c); i += 1 }
            else { break }
        }
        return CGFloat(Double(s) ?? 0)
    }

    /// 弧标志位（0/1），可能与后续数字无分隔（如 `018`）。
    mutating func flag() -> Bool {
        skipSep()
        guard i < chars.count else { return false }
        let c = chars[i]; i += 1
        return c == "1"
    }

    mutating func point(rel: Bool, from cur: CGPoint) -> CGPoint {
        let x = num(), y = num()
        return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
    }
}
