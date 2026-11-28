import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// # USymbol — 放进固定图标框里的 SF Symbol
///
/// `Image(systemName:).font(.system(size:))` 按**字号**排版：同样 13pt，`terminal` 墨迹宽
/// 15pt，`sparkles` 不到 12pt，`person.2` 在 15pt 下宽到 20.5pt。图标只身站在一排等大
/// 方钮里时，这种差异直接表现为「有的塞满、有的空荡」。另外 SF 的排版框带不对称的
/// 边距（`chevron.left` 在框里偏左近 0.9pt），按排版框居中 ≠ 按墨迹居中。
///
/// `USymbol` 先量出符号的**实际墨迹框**，再做两件事：
/// 1. **定大小**：两种口径——
///    - `size` + `box`：按名义字号画，墨迹长边超过 `box` 的等比缩进去（只缩不放：
///      放大会让描边一起变粗，和邻居的笔画对不上）；
///    - `inkArea` + `box`：按**墨迹面积**定大小，让一排图标的视觉重量一致（同字号下
///      `cylinder` 与 `key` 的墨迹面积能差 60%），长边仍不超过 `box`。
/// 2. **按墨迹居中**：偏移掉排版框与墨迹框中心的差。
///
/// ## 为什么在 64pt 画一次再线性缩小
///
/// AppKit 的符号图像会把宽、高**各自**取整到整点，再把字形拉伸进去——按目标字号直接
/// 要图像，形状会被不等比地拉变形（`tablecells` 15pt 时宽高被拉到 18.5×14.5，SwiftUI
/// 自己画是 17.25×13.5），而且墨迹随字号跳变、不单调。在 64pt 要一次图像，取整误差
/// 降到 1% 以内；SF 符号在同一档 scale 内随字号严格线性，缩小后与 `Image(systemName:)`
/// 实测相差不超过 0.25pt。度量（墨迹框、墨迹面积）也就只需按 名字 / 字重 量一次。
///
/// 仅 macOS；其他平台退回 `Image(systemName:)` 原样排版。
public struct USymbol: View {
    let name: String
    let sizing: Sizing
    var weight: Font.Weight
    var box: CGFloat?

    enum Sizing { case pointSize(CGFloat), inkArea(CGFloat) }

    /// 按名义字号画。
    /// - Parameters:
    ///   - size: 名义字号，与 `.font(.system(size:))` 同义。
    ///   - box: 墨迹长边上限；`nil` 只做墨迹居中、不缩。
    public init(_ name: String, size: CGFloat, weight: Font.Weight = .regular, box: CGFloat? = nil) {
        self.name = name
        self.sizing = .pointSize(size)
        self.weight = weight
        self.box = box
    }

    /// 按墨迹面积（pt²）定大小，长边不超过 `box`。用于一排要「看起来一样重」的图标。
    public init(_ name: String, inkArea: CGFloat, weight: Font.Weight = .regular, box: CGFloat? = nil) {
        self.name = name
        self.sizing = .inkArea(inkArea)
        self.weight = weight
        self.box = box
    }

    public var body: some View {
        #if canImport(AppKit)
        if let fit = fitted {
            Image(nsImage: fit.image)
                .renderingMode(.template)
                .resizable()
                .frame(width: fit.frame.width, height: fit.frame.height)
                .offset(fit.offset)
                // 换成位图后 SwiftUI 不再从符号名推无障碍标签，这里补回去。
                .accessibilityRepresentation { Image(systemName: name) }
        } else {
            plain
        }
        #else
        plain
        #endif
    }

    #if canImport(AppKit)
    private var fitted: USymbolMetrics.Fitted? {
        switch sizing {
        case let .pointSize(size): USymbolMetrics.fitted(name, size: size, weight: weight, box: box)
        case let .inkArea(area): USymbolMetrics.fitted(name, inkArea: area, weight: weight, box: box)
        }
    }
    #endif

    private var plain: some View {
        let size: CGFloat = switch sizing {
        case let .pointSize(s): s
        case let .inkArea(a): a.squareRoot() * 2   // 无度量时的粗略回退
        }
        return Image(systemName: name).font(.system(size: size, weight: weight))
    }
}

#if canImport(AppKit)
/// SF Symbol 的墨迹度量（见 `USymbol`）。所有量都在 `referenceSize` 下量一次，按比例换算。
public enum USymbolMetrics {
    /// 参考字号：在这个字号上要图像、量墨迹，然后线性缩放。
    public static let referenceSize: CGFloat = 64

    /// 参考字号下的符号图像、墨迹框（图像坐标，左上原点，pt）与墨迹面积（pt²，按覆盖率累计）。
    public struct Reference: @unchecked Sendable {
        public let image: NSImage
        public let ink: CGRect
        public let inkArea: CGFloat
    }

    /// 定好大小之后：排版框尺寸、框内墨迹框与面积，以及把墨迹中心挪到框中心的偏移。
    public struct Fitted {
        public let image: NSImage
        public let frame: CGSize
        public let ink: CGRect
        public let inkArea: CGFloat
        public let offset: CGSize
    }

    /// 名义字号口径：`size` 下墨迹长边超过 `box` 才等比缩小。
    public static func fitted(_ name: String, size: CGFloat, weight: Font.Weight, box: CGFloat?) -> Fitted? {
        guard let ref = reference(name, weight: weight) else { return nil }
        return fit(ref, scale: size / referenceSize, box: box)
    }

    /// 墨迹面积口径：缩放到墨迹面积恰为 `inkArea`，再受 `box` 约束。
    public static func fitted(_ name: String, inkArea: CGFloat, weight: Font.Weight, box: CGFloat?) -> Fitted? {
        guard let ref = reference(name, weight: weight), ref.inkArea > 0, inkArea > 0 else { return nil }
        return fit(ref, scale: (inkArea / ref.inkArea).squareRoot(), box: box)
    }

    private static func fit(_ ref: Reference, scale: CGFloat, box: CGFloat?) -> Fitted {
        var k = scale
        let extent = max(ref.ink.width, ref.ink.height) * k
        if let box, box > 0, extent > box { k *= box / extent }
        let frame = CGSize(width: ref.image.size.width * k, height: ref.image.size.height * k)
        let ink = CGRect(x: ref.ink.minX * k, y: ref.ink.minY * k, width: ref.ink.width * k, height: ref.ink.height * k)
        return Fitted(image: ref.image, frame: frame, ink: ink, inkArea: ref.inkArea * k * k,
                      offset: CGSize(width: frame.width / 2 - ink.midX, height: frame.height / 2 - ink.midY))
    }

    /// 参考字号下的度量，按 名字 / 字重 缓存。符号不存在或全透明时返回 `nil`。
    public static func reference(_ name: String, weight: Font.Weight) -> Reference? {
        let nsWeight = nsFontWeight(weight)
        let key = Key(name: name, weight: nsWeight.rawValue)
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let image = base.withSymbolConfiguration(.init(pointSize: referenceSize, weight: nsWeight)),
              let (ink, area) = inkBounds(of: image)
        else { return nil }
        let ref = Reference(image: image, ink: ink, inkArea: area)
        cacheLock.lock(); cache[key] = ref; cacheLock.unlock()
        return ref
    }

    private struct Key: Hashable {
        let name: String
        let weight: CGFloat
    }

    nonisolated(unsafe) private static var cache: [Key: Reference] = [:]
    private static let cacheLock = NSLock()

    /// 环形符号（`arrow.clockwise` 这类）原地旋转的轴心：在 `fitted` 排版框里的相对位置（与缩放无关）。
    ///
    /// 墨迹框中心不是圆心——`arrow.clockwise` 的箭头把墨迹框往上撑，12pt 时墨迹框中心比圆心高约 0.9pt，
    /// 绕墨迹框中心转，圆会跟着画小圈（看着晃）。这里对墨迹像素做圆拟合求圆心（剔掉箭头等不在环上的像素后重拟合）。符号不存在或拟合不出（比如不是环形）时返回 nil。
    public static func rotationAnchor(_ name: String, weight: Font.Weight = .regular) -> UnitPoint? {
        let key = Key(name: name, weight: nsFontWeight(weight).rawValue)
        cacheLock.lock()
        if let hit = anchorCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        // 拟合不出（符号不存在 / 圆心落在图外）同样记下：不记的话每次求值都要重新光栅化 + 拟合一遍。
        var anchor: UnitPoint?
        if let ref = reference(name, weight: weight), let center = circleCenter(of: ref.image) {
            let size = ref.image.size
            // 排版框内墨迹框中心已被挪到框中心（见 `fit` 的 offset），圆心相对墨迹框中心的偏移按比例换算。
            anchor = UnitPoint(x: 0.5 + (center.x - ref.ink.midX) / size.width,
                               y: 0.5 + (center.y - ref.ink.midY) / size.height)
        }
        cacheLock.lock(); anchorCache[key] = .some(anchor); cacheLock.unlock()
        return anchor
    }

    /// 测试用：这个符号的轴心是否已经算过（含「算过但为 nil」）。
    static func hasCachedRotationAnchor(_ name: String, weight: Font.Weight = .regular) -> Bool {
        let key = Key(name: name, weight: nsFontWeight(weight).rawValue)
        cacheLock.lock(); defer { cacheLock.unlock() }
        return anchorCache[key] != nil
    }

    nonisolated(unsafe) private static var anchorCache: [Key: UnitPoint?] = [:]

    /// 墨迹像素的圆心（图像坐标，左上原点，pt）：先对全部墨迹做最小二乘圆拟合（Kåsa），再只留离拟合圆
    /// 不远的像素（环上的笔画）重拟合几轮，把箭头这类不在环上的部分剔掉。
    static func circleCenter(of image: NSImage) -> CGPoint? {
        guard let bitmap = alphaBitmap(of: image) else { return nil }
        var points: [(x: Double, y: Double)] = []
        for row in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.alpha(x, row) > 128 {
                points.append((Double(x) + 0.5, Double(row) + 0.5))
            }
        }
        guard var circle = fitCircle(points) else { return nil }
        for _ in 0..<4 {
            let distances = points.map { hypot($0.x - circle.x, $0.y - circle.y) }
            let radius = distances.sorted()[distances.count / 2]
            let tolerance = max(radius * 0.12, 1)
            let ring = zip(points, distances).filter { abs($0.1 - radius) <= tolerance }.map(\.0)
            guard ring.count > 3, let refit = fitCircle(ring) else { break }
            circle = refit
        }
        let scale = Double(bitmap.scale)
        let center = CGPoint(x: circle.x / scale, y: circle.y / scale)
        return CGRect(origin: .zero, size: image.size).contains(center) ? center : nil
    }

    /// 最小二乘圆拟合：解 x² + y² = A·x + B·y + C，圆心 (A/2, B/2)。
    private static func fitCircle(_ points: [(x: Double, y: Double)]) -> (x: Double, y: Double)? {
        guard points.count > 3 else { return nil }
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, sxz = 0.0, syz = 0.0, sz = 0.0
        for p in points {
            let z = p.x * p.x + p.y * p.y
            sx += p.x; sy += p.y; sxx += p.x * p.x; syy += p.y * p.y; sxy += p.x * p.y
            sxz += p.x * z; syz += p.y * z; sz += z
        }
        let n = Double(points.count)
        let m = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]], r = [sxz, syz, sz]
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        func replacing(_ column: Int) -> [[Double]] {
            var copy = m
            for i in 0..<3 { copy[i][column] = r[i] }
            return copy
        }
        let d = det(m)
        guard abs(d) > 1e-9 else { return nil }
        return (det(replacing(0)) / d / 2, det(replacing(1)) / d / 2)
    }

    /// 2× 光栅化后的 alpha（首行 = 图像顶行）。
    private struct AlphaBitmap {
        let width: Int, height: Int, scale: CGFloat
        let bytes: [UInt8], bytesPerRow: Int
        func alpha(_ x: Int, _ row: Int) -> UInt8 { bytes[row * bytesPerRow + x * 4 + 3] }
    }

    private static func alphaBitmap(of image: NSImage) -> AlphaBitmap? {
        let scale: CGFloat = 2
        let w = Int((image.size.width * scale).rounded(.up))
        let h = Int((image.size.height * scale).rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return nil }
        let count = ctx.bytesPerRow * h
        let bytes = Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: count), count: count))
        return AlphaBitmap(width: w, height: h, scale: scale, bytes: bytes, bytesPerRow: ctx.bytesPerRow)
    }

    /// 2× 光栅化后扫 alpha：墨迹框取 > 约 16% 的像素（滤掉抗锯齿最外圈），面积按覆盖率累计。
    private static func inkBounds(of image: NSImage) -> (CGRect, CGFloat)? {
        let scale: CGFloat = 2
        let w = Int((image.size.width * scale).rounded(.up))
        let h = Int((image.size.height * scale).rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // 放大走 CTM、按 pt 尺寸画：NSImage 据此按 2× 设备挑表示、矢量出图。直接往
        // 放大的 rect 里画会先出 1× 位图再拉伸，墨迹被糊大。
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        var coverage = 0
        for row in 0..<h {   // 位图内存首行 = 图像顶行
            let line = bytes + row * ctx.bytesPerRow
            for x in 0..<w {
                let alpha = line[x * 4 + 3]
                coverage += Int(alpha)
                guard alpha > 40 else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if row < minY { minY = row }
                if row > maxY { maxY = row }
            }
        }
        guard maxX >= 0 else { return nil }
        let rect = CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                          width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        return (rect, CGFloat(coverage) / 255 / (scale * scale))
    }

    private static func nsFontWeight(_ w: Font.Weight) -> NSFont.Weight {
        switch w {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
#endif
