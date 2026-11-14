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
/// `USymbol` 先量出符号在给定字号下的**实际墨迹框**，再做两件事：
/// 1. **只缩不放**：墨迹长边超过 `box` 的，把字号等比降到恰好放进 `box`；本来就
///    放得下的保持原字号——放大会让描边一起变粗，和邻居的笔画对不上。
/// 2. **按墨迹居中**：偏移掉排版框与墨迹框中心的差。
///
/// 度量做法是把符号光栅化一次（4×，按 名字 / 字号 / 字重 缓存），一个应用里用到的
/// 组合不过几十个。仅 macOS；其他平台退回 `Image(systemName:)` 原样排版。
public struct USymbol: View {
    let name: String
    var size: CGFloat
    var weight: Font.Weight
    var box: CGFloat?

    /// - Parameters:
    ///   - size: 名义字号，与 `.font(.system(size:))` 同义。
    ///   - box: 墨迹长边上限；`nil` 只做墨迹居中、不缩。
    public init(_ name: String, size: CGFloat, weight: Font.Weight = .regular, box: CGFloat? = nil) {
        self.name = name
        self.size = size
        self.weight = weight
        self.box = box
    }

    public var body: some View {
        #if canImport(AppKit)
        if let fit = USymbolMetrics.fitted(name, size: size, weight: weight, box: box) {
            Image(nsImage: fit.image)
                .renderingMode(.template)
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

    private var plain: some View {
        Image(systemName: name).font(.system(size: size, weight: weight))
    }
}

#if canImport(AppKit)
/// SF Symbol 的墨迹度量（见 `USymbol`）。
public enum USymbolMetrics {
    /// 某字号下的符号图像与其墨迹框（图像坐标，左上原点，单位 pt）。
    public struct Measured: @unchecked Sendable {
        public let image: NSImage
        public let ink: CGRect
    }

    /// 放进 `box` 之后要用的图像，以及把墨迹中心挪到排版框中心所需的偏移。
    public struct Fitted {
        public let image: NSImage
        public let ink: CGRect
        public let offset: CGSize
    }

    public static func fitted(_ name: String, size: CGFloat, weight: Font.Weight, box: CGFloat?) -> Fitted? {
        guard var m = measure(name, size: size, weight: weight) else { return nil }
        if let box, box > 0, extent(m) > box {
            // 墨迹与字号并不严格成正比（AppKit 在非整数字号上会重新取整图像框，实测
            // 15→14.5pt 时 `square.and.arrow.up` 反而变高），所以不能一步按比例算准：
            // 从比例估计出发、以 0.25pt 为步长往下试，直到量出来真的放得进。
            var pt = ((size * box / extent(m)) * 4).rounded(.down) / 4
            var steps = 0
            while pt > 1, steps < 16, let candidate = measure(name, size: pt, weight: weight) {
                m = candidate
                if extent(candidate) <= box { break }
                pt -= 0.25
                steps += 1
            }
        }
        let offset = CGSize(width: m.image.size.width / 2 - m.ink.midX,
                            height: m.image.size.height / 2 - m.ink.midY)
        return Fitted(image: m.image, ink: m.ink, offset: offset)
    }

    private static func extent(_ m: Measured) -> CGFloat { max(m.ink.width, m.ink.height) }

    /// 光栅化一次、按 名字 / 字号 / 字重 缓存。符号不存在或全透明时返回 `nil`。
    public static func measure(_ name: String, size: CGFloat, weight: Font.Weight) -> Measured? {
        let nsWeight = nsFontWeight(weight)
        let key = Key(name: name, size: (size * 64).rounded() / 64, weight: nsWeight.rawValue)
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let image = base.withSymbolConfiguration(.init(pointSize: key.size, weight: nsWeight)),
              let ink = inkRect(of: image)
        else { return nil }
        let measured = Measured(image: image, ink: ink)
        cacheLock.lock(); cache[key] = measured; cacheLock.unlock()
        return measured
    }

    private struct Key: Hashable {
        let name: String
        let size: CGFloat
        let weight: CGFloat
    }

    nonisolated(unsafe) private static var cache: [Key: Measured] = [:]
    private static let cacheLock = NSLock()

    /// 4× 光栅化后扫 alpha（> 约 16% 算墨迹，滤掉抗锯齿的最外圈淡像素）。
    private static func inkRect(of image: NSImage) -> CGRect? {
        let scale: CGFloat = 4
        let w = Int((image.size.width * scale).rounded(.up))
        let h = Int((image.size.height * scale).rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // 放大走 CTM、按 pt 尺寸画：NSImage 据此按 4× 设备挑表示，矢量出图。直接往
        // 4 倍大的 rect 里画会先出 1× 位图再拉伸，墨迹被糊大 0.5–1pt。
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for row in 0..<h {   // 位图内存首行 = 图像顶行
            let line = bytes + row * ctx.bytesPerRow
            for x in 0..<w where line[x * 4 + 3] > 40 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if row < minY { minY = row }
                if row > maxY { maxY = row }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
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
