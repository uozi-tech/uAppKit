import Foundation

/// 对端（服务器）给的文字在拼进文案、日志之前一律过一遍这里。
///
/// 这些文字（SFTP 状态消息、开通道失败的说明、服务器报的算法名、NIOSSH 错误里夹带的对端 DEBUG 文本、退出信号名、
/// 服务器上的文件名、私钥文件里的类型名……）可以是任意 UTF-8，几兆字节，带 ESC / OSC 序列（打到用户的终端里就是
/// 控制命令）、双向文字覆盖符（让「ssh-rsa」显示成别的样子）、换行（伪造日志行）、成串的组合字符（叠成一大坨）。
/// app 把它们放进 alert、日志和命令行工具的输出。
///
/// 在 USSHCore 里（USSHKit 照常可用），这样 USSHCore 自己的日志也能用。
public nonisolated enum SSHPeerText {
    /// 拼进一句话时最多保留这么多个字符（按用户看到的字符算），超过的截断、补「…」。
    public static let maximumLength = 300

    /// `maximumLength` 参数的上限（再大也按这么多算，免得乘法溢出）。
    static let largestAllowedLength = 100_000

    /// 一个基础字符后面最多保留这么多个组合字符 / 变体选择符，多出来的丢掉（正常文字最多两三个）。
    public static let maximumMarksPerCharacter = 4

    /// 去掉 C0 / C1 控制字符（含 ESC、DEL；换行、制表等空白类的换成空格）、双向文字的覆盖 / 隔离符和别的不可见
    /// 格式字符（Unicode 类别 Cf：零宽字符、BOM、软连字符……；U+200D 只在两个 emoji 之间保留，emoji 组合序列不坏）、
    /// 私用区字符、看不见的「字母」填充符（U+115F、U+1160、U+3164、U+FFA0 等），每个字符后面的组合字符最多留
    /// `maximumMarksPerCharacter` 个；连续空白合成一个，去掉首尾空白，最后截断。`maximumLength` 小于 0 按 0 算。
    public static func sanitize(_ text: String, maximumLength: Int = maximumLength) -> String {
        let limit = min(max(maximumLength, 0), largestAllowedLength)
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        var pendingJoiner = false
        var marks = 0
        var previousIsEmoji = false
        // 先粗截：几兆字节的输入不必整份过一遍（一个字符最多由好几个标量组成，留足余量）。
        var budget = limit * 8 + 16
        var inputLeft = false
        for scalar in text.unicodeScalars {
            if budget == 0 {
                inputLeft = true
                break
            }
            budget -= 1
            if isSpace(scalar) {
                pendingSpace = !scalars.isEmpty
                pendingJoiner = false
                previousIsEmoji = false
                continue
            }
            if scalar.value == 0x200D {
                pendingJoiner = previousIsEmoji
                continue
            }
            if isDropped(scalar) {
                continue
            }
            if isMark(scalar) {
                guard !scalars.isEmpty, !pendingSpace, marks < maximumMarksPerCharacter else { continue }
                marks += 1
                scalars.append(scalar)
                continue
            }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            let isEmoji = isEmojiBase(scalar)
            if pendingJoiner, isEmoji { scalars.append("\u{200D}") }
            pendingJoiner = false
            previousIsEmoji = isEmoji
            marks = 0
            scalars.append(scalar)
        }
        let cleaned = String(scalars)
        if cleaned.count > limit || inputLeft {
            return String(cleaned.prefix(limit)) + "…"
        }
        return cleaned
    }

    /// 消毒之后再包进 FSI … PDI（U+2068 … U+2069，first-strong isolate）。把对端文字插进**本地化的句子**时用：
    /// 从右往左书写的文字（阿拉伯文、希伯来文）不会把外面那句话的语序搅乱。日志、给程序读的输出里别用。
    public static func isolated(_ text: String, maximumLength: Int = maximumLength) -> String {
        "\u{2068}" + sanitize(text, maximumLength: maximumLength) + "\u{2069}"
    }

    /// 换成空格的：C0 里的空白（HT、LF、VT、FF、CR）、NEL、行 / 段分隔符与各种空格。
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x2028, 0x2029: return true
        default: return scalar.properties.generalCategory == .spaceSeparator
        }
    }

    /// 直接去掉的：其余 C0 / C1 控制字符与 DEL、全部 Cf（双向覆盖 U+202A–U+202E、隔离 U+2066–U+2069、U+061C、
    /// U+200E / U+200F、零宽字符、BOM……；U+200D 另行处理）、私用区、未分配的码位与看不见的填充符。
    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true
        case 0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800, 0x1D173...0x1D17A: return true   // 填充符、盲文空格、乐谱格式符
        default:
            switch scalar.properties.generalCategory {
            case .format, .privateUse, .surrogate, .unassigned: return true
            default: return false
            }
        }
    }

    /// 组合字符与变体选择符（数个数用）。
    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// 能用 U+200D 接起来的 emoji（不含 ASCII 的数字与 `#` `*`：它们在 Unicode 里也算 Emoji）。
    private static func isEmojiBase(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0x7F && scalar.properties.isEmoji
    }
}
