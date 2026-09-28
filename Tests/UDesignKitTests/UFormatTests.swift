import Foundation
import XCTest
@testable import UDesignKit

/// `UFormat` 的格式契约钉子。所有分档格式化都要「先舍入再选档」，
/// 所以每条档位边界都测「舍入后刚好越档 / 刚好不越档」两侧。
final class UFormatTests: XCTestCase {

    private static let KiB: Int64 = 1024
    private static let MiB: Int64 = 1024 * 1024
    private static let GiB: Int64 = 1024 * 1024 * 1024
    private static let TiB: Int64 = 1024 * GiB
    private static let PiB: Int64 = 1024 * TiB

    // MARK: - bytes

    func testBytesContractExamples() {
        XCTAssertEqual(UFormat.bytes(512 as Int64?), "512 B")
        XCTAssertEqual(UFormat.bytes(1536 as Int64?), "1.50 KB")
        XCTAssertEqual(UFormat.bytes(1_048_575 as Int64?), "1.00 MB")
        XCTAssertEqual(UFormat.bytes(5_000_000 as Int64?), "4.77 MB")
        XCTAssertEqual(UFormat.bytes(3 * Self.GiB), "3.00 GB")
        XCTAssertEqual(UFormat.bytes(Int64(12.3 * Double(Self.GiB))), "12.3 GB")
        XCTAssertEqual(UFormat.bytes(123 * Self.GiB), "123 GB")
        XCTAssertEqual(UFormat.bytes(5 * Self.TiB), "5.00 TB")
        XCTAssertEqual(UFormat.bytes(Self.PiB), "1.00 PB")
    }

    func testBytesNilZeroAndIntOverload() {
        XCTAssertEqual(UFormat.bytes(nil as Int64?), "—")
        XCTAssertEqual(UFormat.bytes(0 as Int64?), "0 B")
        XCTAssertEqual(UFormat.bytes(0), "0 B")
        XCTAssertEqual(UFormat.bytes(1536), "1.50 KB")
        XCTAssertEqual(UFormat.bytes(Int.max), UFormat.bytes(Int64.max))
    }

    func testBytesByteTierBoundary() {
        XCTAssertEqual(UFormat.bytes(1023), "1023 B")
        XCTAssertEqual(UFormat.bytes(1024), "1.00 KB")
        XCTAssertEqual(UFormat.bytes(1025), "1.00 KB")
    }

    func testBytesDecimalBoundariesRoundFirst() {
        // 10 KB：9.994 → 9.99；9.995 → 10.0（不是 "10.00"）
        XCTAssertEqual(UFormat.bytes(10_234), "9.99 KB")
        XCTAssertEqual(UFormat.bytes(10_235), "10.0 KB")
        XCTAssertEqual(UFormat.bytes(10 * Self.KiB), "10.0 KB")
        // 100 KB：99.949 → 99.9；99.950 → 100（不是 "100.0"）
        XCTAssertEqual(UFormat.bytes(102_348), "99.9 KB")
        XCTAssertEqual(UFormat.bytes(102_349), "100 KB")
        XCTAssertEqual(UFormat.bytes(100 * Self.KiB), "100 KB")
        XCTAssertEqual(UFormat.bytes(101 * Self.KiB), "101 KB")
    }

    func testBytesUnitBoundariesRoundFirst() {
        // 1023.499 KB → 1023 KB；1023.5 KB → 1.00 MB（绝不 "1024 KB"）
        XCTAssertEqual(UFormat.bytes(1_048_063), "1023 KB")
        XCTAssertEqual(UFormat.bytes(1_048_064), "1.00 MB")
        XCTAssertEqual(UFormat.bytes(Self.MiB), "1.00 MB")
        XCTAssertEqual(UFormat.bytes(Self.MiB + 1), "1.00 MB")
        XCTAssertEqual(UFormat.bytes(Self.GiB - 1), "1.00 GB")
        XCTAssertEqual(UFormat.bytes(Self.GiB), "1.00 GB")
        XCTAssertEqual(UFormat.bytes(Self.TiB - 1), "1.00 TB")
        XCTAssertEqual(UFormat.bytes(Self.PiB - 1), "1.00 PB")
        XCTAssertEqual(UFormat.bytes(1023 * Self.MiB), "1023 MB")
        XCTAssertEqual(UFormat.bytes(10 * Self.GiB - 1), "10.0 GB")
    }

    func testBytesNeverPrintsFourDigitsInScaledTiers() {
        // 扫一遍各档上沿附近：缩放档里永远不应出现 ≥1024 的数字。
        for unit: Int64 in [Self.KiB, Self.MiB, Self.GiB, Self.TiB] {
            for delta: Int64 in [-unit, -unit / 2, -unit / 1000, -1, 0, 1] {
                let s = UFormat.bytes(1024 * unit + delta)
                XCTAssertFalse(s.hasPrefix("1024"), s)
                XCTAssertFalse(s.hasPrefix("1023.") , s)
            }
        }
    }

    func testBytesNegative() {
        XCTAssertEqual(UFormat.bytes(-512), "-512 B")
        XCTAssertEqual(UFormat.bytes(-1536), "-1.50 KB")
        XCTAssertEqual(UFormat.bytes(-1_048_575), "-1.00 MB")
    }

    func testBytesExtremes() {
        // Int64.max ≈ 8 EiB：多留的 EB 档，不会出现 "8192 PB"，也不崩。
        XCTAssertEqual(UFormat.bytes(Int64.max), "8.00 EB")
        XCTAssertEqual(UFormat.bytes(Int64.min), "-8.00 EB")
        XCTAssertEqual(UFormat.bytes(1024 * Self.PiB), "1.00 EB")
    }

    // MARK: - count

    func testCount() {
        XCTAssertEqual(UFormat.count(nil as Int64?), "—")
        XCTAssertEqual(UFormat.count(0), "0")
        XCTAssertEqual(UFormat.count(7), "7")
        XCTAssertEqual(UFormat.count(999), "999")
        XCTAssertEqual(UFormat.count(1000), "1,000")
        XCTAssertEqual(UFormat.count(12_345), "12,345")
        XCTAssertEqual(UFormat.count(123_456), "123,456")
        XCTAssertEqual(UFormat.count(1_234_567), "1,234,567")
        XCTAssertEqual(UFormat.count(1_234_567 as Int64?), "1,234,567")
        XCTAssertEqual(UFormat.count(-999), "-999")
        XCTAssertEqual(UFormat.count(-1000), "-1,000")
        XCTAssertEqual(UFormat.count(-1234), "-1,234")
    }

    func testCountExtremes() {
        XCTAssertEqual(UFormat.count(Int64.max), "9,223,372,036,854,775,807")
        XCTAssertEqual(UFormat.count(Int64.min), "-9,223,372,036,854,775,808")
        XCTAssertEqual(UFormat.count(Int.min), "-9,223,372,036,854,775,808")
    }

    // MARK: - compact

    func testCompactContractExamples() {
        XCTAssertEqual(UFormat.compact(9_999), "9,999")
        XCTAssertEqual(UFormat.compact(12_345), "12K")
        XCTAssertEqual(UFormat.compact(15_600), "16K")
        XCTAssertEqual(UFormat.compact(999_700), "1.0M")
        XCTAssertEqual(UFormat.compact(1_234_567), "1.2M")
        XCTAssertEqual(UFormat.compact(12_345_678), "12M")
        XCTAssertEqual(UFormat.compact(9_960_000), "10M")
        XCTAssertEqual(UFormat.compact(8_420_000_000), "8.4B")
    }

    func testCompactSmallValuesUseCount() {
        XCTAssertEqual(UFormat.compact(0), "0")
        XCTAssertEqual(UFormat.compact(42), "42")
        XCTAssertEqual(UFormat.compact(1_000), "1,000")
        XCTAssertEqual(UFormat.compact(-9_999), "-9,999")
        XCTAssertEqual(UFormat.compact(10_000), "10K")
        XCTAssertEqual(UFormat.compact(10_001), "10K")
    }

    func testCompactBoundariesRoundFirst() {
        XCTAssertEqual(UFormat.compact(15_500), "16K")          // 四舍五入，不截断
        XCTAssertEqual(UFormat.compact(99_999), "100K")
        XCTAssertEqual(UFormat.compact(999_499), "999K")
        XCTAssertEqual(UFormat.compact(999_500), "1.0M")        // 不是 "1000K"
        XCTAssertEqual(UFormat.compact(999_950), "1.0M")        // 不是 "1000.0K"
        XCTAssertEqual(UFormat.compact(1_000_000), "1.0M")
        XCTAssertEqual(UFormat.compact(9_940_000), "9.9M")
        XCTAssertEqual(UFormat.compact(10_000_000), "10M")
        XCTAssertEqual(UFormat.compact(999_499_999), "999M")
        XCTAssertEqual(UFormat.compact(999_500_000), "1.0B")
        XCTAssertEqual(UFormat.compact(999_999_999_999), "1.0T")
        XCTAssertEqual(UFormat.compact(1_000_000_000_000), "1.0T")
        XCTAssertEqual(UFormat.compact(12_300_000_000_000), "12T")
    }

    func testCompactNegativeAndIntOverload() {
        XCTAssertEqual(UFormat.compact(-12_345), "-12K")
        XCTAssertEqual(UFormat.compact(-999_700), "-1.0M")
        XCTAssertEqual(UFormat.compact(12_345 as Int), "12K")
    }

    func testCompactExtremes() {
        XCTAssertEqual(UFormat.compact(Int64.max), "9,223,372T")
        XCTAssertEqual(UFormat.compact(Int64.min), "-9,223,372T")
        XCTAssertEqual(UFormat.compact(Int.max), UFormat.compact(Int64.max))
    }

    func testApprox() {
        XCTAssertEqual(UFormat.approx("12K"), "≈12K")
        XCTAssertEqual(UFormat.approx(UFormat.compact(1_234_567)), "≈1.2M")
        XCTAssertEqual(UFormat.approx(""), "≈")
    }

    // MARK: - duration

    func testDurationMicroseconds() {
        XCTAssertEqual(UFormat.duration(seconds: 0), "0 µs")
        XCTAssertEqual(UFormat.duration(seconds: -0.0), "0 µs")
        XCTAssertEqual(UFormat.duration(seconds: 0.000412), "412 µs")
        XCTAssertEqual(UFormat.duration(seconds: 0.0000004), "0 µs")
        XCTAssertEqual(UFormat.duration(seconds: 0.0009994), "999 µs")
        // µ 用 U+00B5（MICRO SIGN），不是希腊字母 U+03BC。
        XCTAssertTrue(UFormat.duration(seconds: 0.000412).unicodeScalars.contains("\u{00B5}"))
        XCTAssertFalse(UFormat.duration(seconds: 0.000412).unicodeScalars.contains("\u{03BC}"))
    }

    func testDurationMillisecondsAndSeconds() {
        XCTAssertEqual(UFormat.duration(seconds: 0.00123), "1.23 ms")
        XCTAssertEqual(UFormat.duration(seconds: 0.0123), "12.3 ms")
        XCTAssertEqual(UFormat.duration(seconds: 0.123), "123 ms")
        XCTAssertEqual(UFormat.duration(seconds: 1.23), "1.23 s")
        XCTAssertEqual(UFormat.duration(seconds: 12.3), "12.3 s")
        XCTAssertEqual(UFormat.duration(seconds: 59.94), "59.9 s")
    }

    func testDurationBoundariesRoundFirst() {
        XCTAssertEqual(UFormat.duration(seconds: 0.0009996), "1.00 ms")   // 不是 "1000 µs"
        XCTAssertEqual(UFormat.duration(seconds: 0.001), "1.00 ms")
        XCTAssertEqual(UFormat.duration(seconds: 0.009994), "9.99 ms")
        XCTAssertEqual(UFormat.duration(seconds: 0.009996), "10.0 ms")    // 不是 "10.00 ms"
        XCTAssertEqual(UFormat.duration(seconds: 0.09994), "99.9 ms")
        XCTAssertEqual(UFormat.duration(seconds: 0.09996), "100 ms")      // 不是 "100.0 ms"
        XCTAssertEqual(UFormat.duration(seconds: 0.9994), "999 ms")
        XCTAssertEqual(UFormat.duration(seconds: 0.99996), "1.00 s")      // 不是 "1000 ms"
        XCTAssertEqual(UFormat.duration(seconds: 1), "1.00 s")
        XCTAssertEqual(UFormat.duration(seconds: 9.996), "10.0 s")
        XCTAssertEqual(UFormat.duration(seconds: 59.96), "1m 00s")
        XCTAssertEqual(UFormat.duration(seconds: 59.996), "1m 00s")       // 不是 "60.00 s"
        XCTAssertEqual(UFormat.duration(seconds: 60), "1m 00s")
    }

    func testDurationMinutesAndHours() {
        XCTAssertEqual(UFormat.duration(seconds: 125), "2m 05s")
        XCTAssertEqual(UFormat.duration(seconds: 125.43), "2m 05s")
        XCTAssertEqual(UFormat.duration(seconds: 125.5), "2m 06s")
        XCTAssertEqual(UFormat.duration(seconds: 3599.4), "59m 59s")
        XCTAssertEqual(UFormat.duration(seconds: 3599.5), "1h 00m")       // 不是 "60m 00s"
        XCTAssertEqual(UFormat.duration(seconds: 3600), "1h 00m")
        XCTAssertEqual(UFormat.duration(seconds: 3720), "1h 02m")
        XCTAssertEqual(UFormat.duration(seconds: 7500), "2h 05m")
        XCTAssertEqual(UFormat.duration(seconds: 7229), "2h 00m")
        XCTAssertEqual(UFormat.duration(seconds: 7230), "2h 01m")
        XCTAssertEqual(UFormat.duration(seconds: 2 * 3600 + 59 * 60 + 45), "3h 00m")
        XCTAssertEqual(UFormat.duration(seconds: 100 * 3600), "100h 00m")
    }

    func testDurationInvalidInputs() {
        XCTAssertEqual(UFormat.duration(seconds: -1), "—")
        XCTAssertEqual(UFormat.duration(seconds: -0.000001), "—")
        XCTAssertEqual(UFormat.duration(seconds: .nan), "—")
        XCTAssertEqual(UFormat.duration(seconds: .infinity), "—")
        XCTAssertEqual(UFormat.duration(seconds: -.infinity), "—")
        XCTAssertEqual(UFormat.duration(milliseconds: .nan), "—")
        XCTAssertEqual(UFormat.duration(milliseconds: -5), "—")
    }

    func testDurationHugeValuesDoNotCrash() {
        XCTAssertTrue(UFormat.duration(seconds: 1e300).hasSuffix("m"))
        XCTAssertTrue(UFormat.duration(seconds: .greatestFiniteMagnitude).hasSuffix("m"))
        XCTAssertTrue(UFormat.duration(.seconds(Int64.max)).hasSuffix("m"))
    }

    func testDurationOverloads() {
        XCTAssertEqual(UFormat.duration(.microseconds(412)), "412 µs")
        XCTAssertEqual(UFormat.duration(.milliseconds(1500)), "1.50 s")
        XCTAssertEqual(UFormat.duration(.seconds(125)), "2m 05s")
        XCTAssertEqual(UFormat.duration(.zero), "0 µs")
        XCTAssertEqual(UFormat.duration(.seconds(-1)), "—")
        XCTAssertEqual(UFormat.duration(milliseconds: 0.412), "412 µs")
        XCTAssertEqual(UFormat.duration(milliseconds: 12.3), "12.3 ms")
        XCTAssertEqual(UFormat.duration(milliseconds: 0.9996), "1.00 ms")
        XCTAssertEqual(UFormat.duration(milliseconds: 999.96), "1.00 s")
        XCTAssertEqual(UFormat.duration(milliseconds: 59_996), "1m 00s")
    }

    // MARK: - percent

    func testPercent() {
        XCTAssertEqual(UFormat.percent(0.42), "42%")
        XCTAssertEqual(UFormat.percent(0.987, decimals: 1), "98.7%")
        XCTAssertEqual(UFormat.percent(0), "0%")
        XCTAssertEqual(UFormat.percent(1), "100%")
        XCTAssertEqual(UFormat.percent(0.994), "99%")
        XCTAssertEqual(UFormat.percent(0.999), "100%")          // 四舍五入，不是截断成 99%
        XCTAssertEqual(UFormat.percent(0.004), "0%")
        XCTAssertEqual(UFormat.percent(0.006), "1%")
        XCTAssertEqual(UFormat.percent(0.123456, decimals: 2), "12.35%")
        XCTAssertEqual(UFormat.percent(0.5, decimals: 1), "50.0%")
        XCTAssertEqual(UFormat.percent(0.42, decimals: -3), "42%")
    }

    func testPercentDoesNotClampAndHasNoNegativeZero() {
        XCTAssertEqual(UFormat.percent(1.5), "150%")
        XCTAssertEqual(UFormat.percent(-0.25), "-25%")
        XCTAssertEqual(UFormat.percent(-0.001), "0%")
        XCTAssertEqual(UFormat.percent(-0.0001, decimals: 1), "0.0%")
    }

    func testPercentNonFinite() {
        XCTAssertEqual(UFormat.percent(.nan), "—")
        XCTAssertEqual(UFormat.percent(.infinity), "—")
        XCTAssertEqual(UFormat.percent(-.infinity, decimals: 1), "—")
        XCTAssertEqual(UFormat.percent(.greatestFiniteMagnitude), "—")   // ×100 溢出
    }

    // MARK: - 时间戳

    private static let utc = TimeZone(identifier: "UTC")!
    private static let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    private static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0,
                             ms: Int = 0, tz: TimeZone = utc) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let base = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
        return base.addingTimeInterval(Double(ms) / 1000)
    }

    func testTimestampFormats() {
        let d = Self.date(2026, 9, 28, 13, 5, 7, ms: 123)
        XCTAssertEqual(UFormat.dateTime(d, timeZone: Self.utc), "2026-09-28 13:05:07")
        XCTAssertEqual(UFormat.dateTimeMillis(d, timeZone: Self.utc), "2026-09-28 13:05:07.123")
        XCTAssertEqual(UFormat.dateTimeMinutes(d, timeZone: Self.utc), "2026-09-28 13:05")
        XCTAssertEqual(UFormat.time(d, timeZone: Self.utc), "13:05:07")
        XCTAssertEqual(UFormat.timeMillis(d, timeZone: Self.utc), "13:05:07.123")
        XCTAssertEqual(UFormat.monthDayTime(d, timeZone: Self.utc), "09/28 13:05:07")
    }

    func testTimestampPaddingAnd24Hour() {
        let midnight = Self.date(2026, 1, 2, 0, 0, 0)
        XCTAssertEqual(UFormat.dateTime(midnight, timeZone: Self.utc), "2026-01-02 00:00:00")
        XCTAssertEqual(UFormat.monthDayTime(midnight, timeZone: Self.utc), "01/02 00:00:00")
        let evening = Self.date(2026, 12, 31, 23, 59, 59)
        XCTAssertEqual(UFormat.time(evening, timeZone: Self.utc), "23:59:59")
        let early = Self.date(999, 3, 4, 5, 6, 7)
        XCTAssertEqual(UFormat.dateTime(early, timeZone: Self.utc), "0999-03-04 05:06:07")
    }

    func testMillisecondsPadAndTruncate() {
        XCTAssertEqual(UFormat.timeMillis(Self.date(2026, 9, 28, 13, 5, 7, ms: 7), timeZone: Self.utc), "13:05:07.007")
        XCTAssertEqual(UFormat.timeMillis(Self.date(2026, 9, 28, 13, 5, 7, ms: 50), timeZone: Self.utc), "13:05:07.050")
        XCTAssertEqual(UFormat.timeMillis(Self.date(2026, 9, 28, 13, 5, 7, ms: 0), timeZone: Self.utc), "13:05:07.000")
        XCTAssertEqual(UFormat.timeMillis(Self.date(2026, 9, 28, 13, 5, 7, ms: 999), timeZone: Self.utc), "13:05:07.999")
        // .9996 截断成 .999，秒不进位（避免秒与毫秒自相矛盾）。
        let almost = Self.date(2026, 9, 28, 13, 5, 7).addingTimeInterval(0.9996)
        XCTAssertEqual(UFormat.timeMillis(almost, timeZone: Self.utc), "13:05:07.999")
        XCTAssertEqual(UFormat.time(almost, timeZone: Self.utc), "13:05:07")
        // 1970 之前（时间戳为负）同样按向下取整拆秒。
        let pre = Self.date(1960, 6, 1, 12, 0, 0, ms: 250)
        XCTAssertEqual(UFormat.dateTimeMillis(pre, timeZone: Self.utc), "1960-06-01 12:00:00.250")
    }

    func testTimestampTimeZone() {
        let d = Self.date(2026, 9, 28, 20, 30, 0)
        XCTAssertEqual(UFormat.dateTime(d, timeZone: Self.shanghai), "2026-09-29 04:30:00")
        XCTAssertEqual(UFormat.monthDayTime(d, timeZone: Self.shanghai), "09/29 04:30:00")
        // 无 timeZone 参数的版本等价于显式传 TimeZone.current。
        XCTAssertEqual(UFormat.dateTime(d), UFormat.dateTime(d, timeZone: .current))
        XCTAssertEqual(UFormat.dateTimeMillis(d), UFormat.dateTimeMillis(d, timeZone: .current))
        XCTAssertEqual(UFormat.dateTimeMinutes(d), UFormat.dateTimeMinutes(d, timeZone: .current))
        XCTAssertEqual(UFormat.time(d), UFormat.time(d, timeZone: .current))
        XCTAssertEqual(UFormat.timeMillis(d), UFormat.timeMillis(d, timeZone: .current))
        XCTAssertEqual(UFormat.monthDayTime(d), UFormat.monthDayTime(d, timeZone: .current))
    }

    func testTimestampExtremesDoNotCrash() {
        XCTAssertFalse(UFormat.dateTime(.distantPast, timeZone: Self.utc).isEmpty)
        XCTAssertFalse(UFormat.dateTimeMillis(.distantFuture, timeZone: Self.utc).isEmpty)
    }

    // MARK: - relative

    private static func utcCalendar(_ tz: TimeZone = utc, _ id: Calendar.Identifier = .gregorian) -> Calendar {
        var c = Calendar(identifier: id)
        c.timeZone = tz
        return c
    }

    func testRelativeRecent() {
        let now = Self.date(2026, 9, 28, 12, 0, 0)
        let cal = Self.utcCalendar()
        func rel(_ offset: TimeInterval) -> String {
            UFormat.relative(now.addingTimeInterval(offset), now: now, calendar: cal)
        }
        XCTAssertEqual(rel(3600), "刚刚")          // 未来
        XCTAssertEqual(rel(0), "刚刚")
        XCTAssertEqual(rel(-59.9), "刚刚")
        XCTAssertEqual(rel(-60), "1 分钟前")
        XCTAssertEqual(rel(-119), "1 分钟前")
        XCTAssertEqual(rel(-3599), "59 分钟前")
        XCTAssertEqual(rel(-3600), "1 小时前")
        XCTAssertEqual(rel(-(23 * 3600 + 3599)), "23 小时前")
        // 跨过午夜但不满 24 小时：仍然是「N 小时前」。
        XCTAssertEqual(UFormat.relative(Self.date(2026, 9, 27, 23, 0, 0), now: now, calendar: cal), "13 小时前")
    }

    func testRelativeDays() {
        let now = Self.date(2026, 9, 28, 12, 0, 0)
        let cal = Self.utcCalendar()
        func rel(_ date: Date) -> String { UFormat.relative(date, now: now, calendar: cal) }
        XCTAssertEqual(rel(Self.date(2026, 9, 27, 12, 0, 0)), "昨天")
        XCTAssertEqual(rel(Self.date(2026, 9, 27, 0, 0, 0)), "昨天")
        XCTAssertEqual(rel(Self.date(2026, 9, 26, 23, 0, 0)), "2 天前")     // 按日历日差，不是 37h/24
        XCTAssertEqual(rel(Self.date(2026, 9, 22, 0, 0, 0)), "6 天前")
        XCTAssertEqual(rel(Self.date(2026, 9, 21, 23, 59, 0)), "09-21")
        XCTAssertEqual(rel(Self.date(2026, 1, 1, 0, 0, 0)), "01-01")
        XCTAssertEqual(rel(Self.date(2025, 12, 31, 23, 0, 0)), "2025-12-31")
        XCTAssertEqual(rel(Self.date(1999, 5, 6, 0, 0, 0)), "1999-05-06")
    }

    func testRelativeUsesCalendarTimeZone() {
        let now = Self.date(2026, 9, 28, 12, 0, 0)
        let date = Self.date(2026, 9, 26, 17, 0, 0)   // UTC 9/26；上海 9/27 01:00
        XCTAssertEqual(UFormat.relative(date, now: now, calendar: Self.utcCalendar()), "2 天前")
        XCTAssertEqual(UFormat.relative(date, now: now, calendar: Self.utcCalendar(Self.shanghai)), "昨天")
    }

    func testRelativeYearIsAlwaysGregorian() {
        // 系统日历设成佛历 / 和历时，年份也不能渲染成 2568 或令和纪年。
        let now = Self.date(2026, 9, 28, 12, 0, 0)
        let old = Self.date(2025, 12, 31, 23, 0, 0)
        for id: Calendar.Identifier in [.buddhist, .japanese, .republicOfChina, .islamic] {
            XCTAssertEqual(UFormat.relative(old, now: now, calendar: Self.utcCalendar(Self.utc, id)), "2025-12-31", "\(id)")
            XCTAssertEqual(UFormat.relative(Self.date(2026, 3, 4), now: now, calendar: Self.utcCalendar(Self.utc, id)), "03-04", "\(id)")
        }
    }

    // MARK: - locale 无关

    /// 构造上与 locale 无关：实现里不得出现任何会读 locale 的 API。
    /// 同时核对输出里只有 "." 小数点、"," 千分位。
    func testNoLocaleDependenceByConstruction() throws {
        let source = try String(contentsOf: Self.sourceURL, encoding: .utf8)
        let code = source
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for banned in ["Locale", "DateFormatter", "NumberFormatter", "ByteCountFormatter",
                       ".formatted(", "String(format: \"%'", "localizedString", "Calendar.current"] {
            XCTAssertFalse(code.contains(banned), "UFormat 不得依赖 locale：出现了 \(banned)")
        }
        XCTAssertEqual(UFormat.bytes(1536), "1.50 KB")
        XCTAssertEqual(UFormat.percent(0.987, decimals: 1), "98.7%")
        XCTAssertEqual(UFormat.count(1_234_567), "1,234,567")
    }

    func testSourceGuardCanReadTheSource() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.sourceURL.path),
                      "找不到 UFormat.swift，源码守卫已失效：\(Self.sourceURL.path)")
    }

    /// 并发调用不会互相干扰（无共享可变状态）。
    func testConcurrentUseIsSafe() {
        let d = Self.date(2026, 9, 28, 13, 5, 7, ms: 123)
        DispatchQueue.concurrentPerform(iterations: 2000) { i in
            XCTAssertEqual(UFormat.dateTimeMillis(d, timeZone: Self.utc), "2026-09-28 13:05:07.123")
            XCTAssertEqual(UFormat.bytes(Int64(i) * 1024 + 1024 * 1024), UFormat.bytes(Int64(i) * 1024 + 1024 * 1024))
            XCTAssertEqual(UFormat.compact(999_700), "1.0M")
        }
    }

    private static var sourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UDesignKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <包根>
            .appendingPathComponent("Sources/UDesignKit/Formatting/UFormat.swift")
    }
}
