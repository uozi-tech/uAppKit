import Foundation

/// 统一的数字 / 时间渲染层：字节、计数、耗时、百分比、时间戳在各 app 里只有一种写法。
///
/// 约定：
/// - 纯函数，任何 isolation 都能调（驱动、Core、AppKit 自绘）。
/// - 与系统 locale 无关：小数点恒为 "."，千分位恒为 ","，日期恒为公历 + 24 小时制。
///   数字走 `String(format:)`（不传 locale 即 POSIX）+ 手写分组；日期走公历 Calendar
///   取分量后手工拼接，不经过任何 DateFormatter，因此也没有共享可变状态。
/// - 所有分档格式化一律「先舍入再选档」：1,048,575 B → "1.00 MB" 而非 "1024.0 KB"；
///   999,950 → "1.0M" 而非 "1000.0K"；59.996 s → "1m 00s" 而非 "60.00 s"。
nonisolated public enum UFormat {

    /// 缺值占位（nil、负耗时、非有限数）。
    public static let placeholder = "—"

    // MARK: - 字节

    private static let byteUnits = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]

    /// 字节：1024 进制，B 档整数，其余档三位有效数字（"1.50 KB" "12.3 GB" "123 GB"）。
    /// Int64 上限约 8 EiB，故在契约的 PB 之上多留一档 EB，免得出现 "8192 PB"。
    public static func bytes(_ value: Int64?) -> String {
        guard let value else { return placeholder }
        let sign = value < 0 ? "-" : ""
        let magnitude = value.magnitude
        if magnitude < 1024 { return "\(sign)\(magnitude) B" }

        var unit = 1
        var scaled = Double(magnitude) / 1024
        while scaled >= 1024, unit < byteUnits.count - 1 {
            scaled /= 1024
            unit += 1
        }
        var (rounded, decimals) = threeSignificant(scaled)
        // 舍入后满 1024 → 进位到下一档（如 1023.6 KB → 1.00 MB）。
        if rounded >= 1024, unit < byteUnits.count - 1 {
            scaled /= 1024
            unit += 1
            (rounded, decimals) = threeSignificant(scaled)
        }
        return "\(sign)\(fixed(rounded, decimals)) \(byteUnits[unit])"
    }

    public static func bytes(_ value: Int) -> String { bytes(Int64(value)) }

    // MARK: - 计数

    /// 千分位整数："1,234,567"、"-1,234"。
    public static func count(_ value: Int64?) -> String {
        guard let value else { return placeholder }
        return (value < 0 ? "-" : "") + grouped(value.magnitude)
    }

    public static func count(_ value: Int) -> String { count(Int64(value)) }

    private static let compactUnits = ["", "K", "M", "B", "T"]

    /// 紧凑计数：|n| < 10,000 走千分位；否则 K/M/B/T，缩放后 <10 一位小数、否则整数。
    public static func compact(_ value: Int64) -> String {
        let magnitude = value.magnitude
        if magnitude < 10_000 { return count(value) }
        let sign = value < 0 ? "-" : ""

        var unit = 1
        var scaled = Double(magnitude) / 1000
        while scaled >= 1000, unit < compactUnits.count - 1 {
            scaled /= 1000
            unit += 1
        }
        var (rounded, decimals) = compactDigits(scaled)
        // 舍入后满 1000 → 进位（999.7K → 1.0M）。
        if rounded >= 1000, unit < compactUnits.count - 1 {
            scaled /= 1000
            unit += 1
            (rounded, decimals) = compactDigits(scaled)
        }
        let digits: String
        if decimals == 0, rounded >= 1000, rounded < 1e18 {
            // 仅 T 档之上会走到：9,223,372T。
            digits = grouped(UInt64(rounded))
        } else {
            digits = fixed(rounded, decimals)
        }
        return "\(sign)\(digits)\(compactUnits[unit])"
    }

    public static func compact(_ value: Int) -> String { compact(Int64(value)) }

    /// 估算值前缀：统一 "≈"，不带空格。
    public static func approx(_ text: String) -> String { "≈" + text }

    // MARK: - 耗时

    /// 耗时：µs（整数）→ ms / s（三位有效数字）→ "2m 05s" → "1h 02m" → "3d 04h"。
    /// 负数 / 非有限 → "—"。
    public static func duration(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return placeholder }

        if seconds < 1e-3 {
            let micros = (seconds * 1e6).rounded(.toNearestOrAwayFromZero)
            if micros < 1000 { return "\(Int(micros)) µs" }
        }
        if seconds < 1 {
            let (ms, d) = threeSignificant(seconds * 1000)
            if ms < 1000 { return "\(fixed(ms, d)) ms" }
        }
        if seconds < 60 {
            let (s, d) = threeSignificant(seconds)
            if s < 60 { return "\(fixed(s, d)) s" }
        }
        let totalSeconds = seconds.rounded(.toNearestOrAwayFromZero)
        if totalSeconds < 3600 {
            let m = Int(totalSeconds) / 60
            let s = Int(totalSeconds) % 60
            return "\(m)m " + twoDigits(s) + "s"
        }
        let totalMinutes = (seconds / 60).rounded(.toNearestOrAwayFromZero)
        if totalMinutes < 24 * 60 {
            let hours = (totalMinutes / 60).rounded(.down)
            let minutes = Int(totalMinutes - hours * 60)
            return String(format: "%.0fh ", hours) + twoDigits(minutes) + "m"
        }
        // ≥ 1 天：「3d 04h」（23h 59m 40s 舍入后满一天 → "1d 00h"）。
        let totalHours = (seconds / 3600).rounded(.toNearestOrAwayFromZero)
        let days = (totalHours / 24).rounded(.down)
        let hours = Int(totalHours - days * 24)
        return String(format: "%.0fd ", days) + twoDigits(hours) + "h"
    }

    /// 整秒时长（TTL、存活时长、剩余时间这类本就以秒计的量）：不满一分钟写 "45 s"，
    /// 不带 `duration(seconds:)` 的小数位（"45.0 s"）；一分钟起同 `duration(seconds:)`。
    public static func duration(wholeSeconds: Int64) -> String {
        guard wholeSeconds >= 0 else { return placeholder }
        if wholeSeconds < 60 { return "\(wholeSeconds) s" }
        return duration(seconds: Double(wholeSeconds))
    }

    public static func duration(_ d: Duration) -> String {
        let c = d.components
        return duration(seconds: Double(c.seconds) + Double(c.attoseconds) * 1e-18)
    }

    public static func duration(milliseconds: Double) -> String {
        duration(seconds: milliseconds / 1000)
    }

    // MARK: - 百分比

    /// 百分比：fraction 为 0…1，四舍五入到 decimals 位。不钳制。
    public static func percent(_ fraction: Double, decimals: Int = 0) -> String {
        let d = min(max(decimals, 0), 6)
        let rounded = round(fraction * 100, d)
        guard rounded.isFinite else { return placeholder }
        // 抹掉 "-0%"。
        return fixed(rounded == 0 ? 0 : rounded, d) + "%"
    }

    // MARK: - 时间戳

    /// 公历、无 locale 依赖。无 timeZone 参数的版本取调用那一刻的 TimeZone.current；
    /// 带 timeZone 的重载供测试与需要固定时区（如 UTC）的调用方使用。
    private static let gregorian = Calendar(identifier: .gregorian)

    /// "2026-09-28 13:05:07"
    public static func dateTime(_ date: Date) -> String { dateTime(date, timeZone: .current) }
    public static func dateTime(_ date: Date, timeZone: TimeZone) -> String {
        let p = parts(date, timeZone)
        return p.ymd + " " + p.hms
    }

    /// "2026-09-28 13:05:07.123"（毫秒截断，不进位到秒）
    public static func dateTimeMillis(_ date: Date) -> String { dateTimeMillis(date, timeZone: .current) }
    public static func dateTimeMillis(_ date: Date, timeZone: TimeZone) -> String {
        let p = parts(date, timeZone)
        return p.ymd + " " + p.hms + "." + p.millis
    }

    /// "2026-09-28 13:05"
    public static func dateTimeMinutes(_ date: Date) -> String { dateTimeMinutes(date, timeZone: .current) }
    public static func dateTimeMinutes(_ date: Date, timeZone: TimeZone) -> String {
        let p = parts(date, timeZone)
        return p.ymd + " " + p.hm
    }

    /// "13:05:07"
    public static func time(_ date: Date) -> String { time(date, timeZone: .current) }
    public static func time(_ date: Date, timeZone: TimeZone) -> String {
        parts(date, timeZone).hms
    }

    /// "13:05:07.123"
    public static func timeMillis(_ date: Date) -> String { timeMillis(date, timeZone: .current) }
    public static func timeMillis(_ date: Date, timeZone: TimeZone) -> String {
        let p = parts(date, timeZone)
        return p.hms + "." + p.millis
    }

    /// "09/28 13:05:07"
    public static func monthDayTime(_ date: Date) -> String { monthDayTime(date, timeZone: .current) }
    public static func monthDayTime(_ date: Date, timeZone: TimeZone) -> String {
        let p = parts(date, timeZone)
        return twoDigits(p.month) + "/" + twoDigits(p.day) + " " + p.hms
    }

    // MARK: - 相对时间

    /// 相对时间（中文）："刚刚" / "N 分钟前" / "N 小时前" / "昨天" / "N 天前" / "MM-dd" / "yyyy-MM-dd"。
    /// 只取 `calendar` 的时区；日历日与年份一律按公历算（避免佛历/和历年份）。
    public static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return String(localized: "刚刚", bundle: ModuleBundle.bundle) }
        if elapsed < 3600 { let minutes = Int(elapsed / 60); return String(localized: "\(minutes) 分钟前", bundle: ModuleBundle.bundle) }
        let hours = Int(elapsed / 3600)
        let hoursText = String(localized: "\(hours) 小时前", bundle: ModuleBundle.bundle)
        if elapsed < 86_400 { return hoursText }

        var g = gregorian
        g.timeZone = calendar.timeZone
        let dayDiff = g.dateComponents([.day], from: g.startOfDay(for: date), to: g.startOfDay(for: now)).day ?? 0
        if dayDiff <= 0 { return hoursText }   // 25 小时的 DST 日内
        if dayDiff == 1 { return String(localized: "昨天", bundle: ModuleBundle.bundle) }
        if dayDiff < 7 { return String(localized: "\(dayDiff) 天前", bundle: ModuleBundle.bundle) }

        let d = g.dateComponents([.year, .month, .day], from: date)
        let md = twoDigits(d.month ?? 0) + "-" + twoDigits(d.day ?? 0)
        if d.year == g.component(.year, from: now) { return md }
        return fourDigits(d.year ?? 0) + "-" + md
    }

    // MARK: - 内部

    /// 三位有效数字：<10 → 2 位小数，<100 → 1 位，否则 0 位；舍入越档时降一位小数重舍
    /// （9.996 → 10.0，99.96 → 100）。x 须 ≥ 0。
    private static func threeSignificant(_ x: Double) -> (value: Double, decimals: Int) {
        var d = x < 10 ? 2 : (x < 100 ? 1 : 0)
        var r = round(x, d)
        if d == 2, r >= 10 { d = 1; r = round(x, 1) }
        if d == 1, r >= 100 { d = 0; r = round(x, 0) }
        return (r, d)
    }

    /// 紧凑计数的位数：<10 → 1 位小数，否则整数；9.96 → 10。
    private static func compactDigits(_ x: Double) -> (value: Double, decimals: Int) {
        if x < 10 {
            let r = round(x, 1)
            if r < 10 { return (r, 1) }
        }
        return (round(x, 0), 0)
    }

    private static func round(_ x: Double, _ decimals: Int) -> Double {
        guard decimals > 0 else { return x.rounded(.toNearestOrAwayFromZero) }
        let scale = pow(10, Double(decimals))
        return (x * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    /// 固定小数位，恒用 "."（String(format:) 不传 locale 即 POSIX）。
    private static func fixed(_ x: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", x)
    }

    private static func grouped(_ magnitude: UInt64) -> String {
        let digits = String(magnitude)
        guard digits.count > 3 else { return digits }
        var out = ""
        out.reserveCapacity(digits.count + digits.count / 3)
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }

    private static func twoDigits(_ n: Int) -> String {
        n >= 0 && n < 10 ? "0\(n)" : "\(n)"
    }

    private static func fourDigits(_ n: Int) -> String {
        let s = String(n)
        return s.count >= 4 ? s : String(repeating: "0", count: 4 - s.count) + s
    }

    private struct Parts {
        var year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, millisecond: Int
        var ymd: String { UFormat.fourDigits(year) + "-" + UFormat.twoDigits(month) + "-" + UFormat.twoDigits(day) }
        var hm: String { UFormat.twoDigits(hour) + ":" + UFormat.twoDigits(minute) }
        var hms: String { hm + ":" + UFormat.twoDigits(second) }
        var millis: String {
            millisecond < 10 ? "00\(millisecond)" : (millisecond < 100 ? "0\(millisecond)" : "\(millisecond)")
        }
    }

    /// 秒向下取整后取公历分量，毫秒由小数部分截断得出——秒与毫秒永远一致，不会出现 ".1000"。
    private static func parts(_ date: Date, _ timeZone: TimeZone) -> Parts {
        let t = date.timeIntervalSinceReferenceDate
        let whole = t.rounded(.down)
        // +1µs 吸收二进制浮点误差（.123 存成 .12299999…）。
        let ms = min(999, max(0, Int(((t - whole) * 1000 + 1e-3).rounded(.down))))
        var g = gregorian
        g.timeZone = timeZone
        let c = g.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                 from: Date(timeIntervalSinceReferenceDate: whole))
        return Parts(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0,
                     hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0,
                     millisecond: ms)
    }
}
