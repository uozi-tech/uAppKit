import Foundation

/// 对端（服务器）给的文字在拼进文案、日志之前一律过一遍这里。
///
/// 这些文字（SFTP 状态消息、开通道失败的说明、服务器报的算法名、NIOSSH 错误里夹带的对端 DEBUG 文本、退出信号名、
/// 私钥文件里的类型名……）可以是任意 UTF-8，几兆字节，带 ESC / OSC 序列（打到用户的终端里就是控制命令）、
/// 双向文字覆盖符（让「ssh-rsa」显示成别的样子）、换行（伪造日志行）。app 把它们放进 alert、日志和命令行工具的输出。
nonisolated enum SSHPeerText {
    /// 拼进一句话时最多保留这么多个字符（按用户看到的字符算），超过的截断、补「…」。
    static let maximumLength = 300

    /// 去掉 C0 / C1 控制字符（含 ESC、DEL；换行、制表等空白类的换成空格）、双向文字的覆盖 / 隔离符和别的不可见
    /// 格式字符（Unicode 类别 Cf：零宽字符、BOM、软连字符……），连续空白合成一个，去掉首尾空白，最后截断。
    static func sanitize(_ text: String, maximumLength: Int = maximumLength) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        // 先粗截：几兆字节的输入不必整份过一遍（一个字符最多由好几个标量组成，留足余量）。
        var budget = maximumLength * 8 + 16
        var inputLeft = false
        for scalar in text.unicodeScalars {
            if budget == 0 {
                inputLeft = true
                break
            }
            budget -= 1
            if isSpace(scalar) {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if isDropped(scalar) { continue }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        let cleaned = String(scalars)
        if cleaned.count > maximumLength || inputLeft {
            return String(cleaned.prefix(maximumLength)) + "…"
        }
        return cleaned
    }

    /// 换成空格的：C0 里的空白（HT、LF、VT、FF、CR）、NEL、行 / 段分隔符与各种空格。
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x2028, 0x2029: return true
        default: return scalar.properties.generalCategory == .spaceSeparator
        }
    }

    /// 直接去掉的：其余 C0 / C1 控制字符与 DEL，以及全部 Cf（双向覆盖 U+202A–U+202E、隔离 U+2066–U+2069、
    /// U+061C、U+200E / U+200F、零宽字符、BOM……都属于它）。
    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true
        default: return scalar.properties.generalCategory == .format
        }
    }
}
